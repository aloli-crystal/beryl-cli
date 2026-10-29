require "../primitive"

module Beryl::Apply
  # Primitive `pf-rule` : ajoute/retire une règle dans un bloc géré par
  # beryl à l'intérieur de `/etc/pf.conf`. Le reste du fichier (macros,
  # tables, règles de l'opérateur) n'est jamais touché.
  #
  # Idempotence : diff par ligne dans le bloc géré (marqueurs
  # `# >>> beryl >>>` / `# <<< beryl <<<`). La règle est validée
  # (`pfctl -nf` sur un fichier temporaire) AVANT d'écraser pf.conf,
  # puis chargée (`pfctl -f`).
  #
  #     - pf-rule:
  #         rule: "block in quick proto tcp to port 23"
  #         state: present     # ou absent (défaut present)
  #
  # `nat: true` place la règle dans un bloc de TRANSLATION distinct, inséré
  # AVANT les règles filtre (pf impose l'ordre options→scrub→translation→
  # filtre ; un `nat` en fin de fichier ferait échouer `pfctl`). Pour les
  # règles `nat`/`rdr`/`binat` (ex. NAT sortant d'un exit-node VPN) :
  #
  #     - pf-rule:
  #         nat: true
  #         rule: "nat on egress from 100.64.0.0/10 to any -> (egress)"
  #
  # `before: <règle>` insère la règle JUSTE AVANT une règle déjà présente du
  # bloc (sinon : en fin de bloc). Indispensable pour un `pass quick` ajouté
  # après coup devant un `block quick` déjà posé : en fin de bloc, il ne
  # serait jamais atteint. `if_set: "{{ var }}"` saute l'étape si la valeur
  # est vide (règle facultative).
  #
  #     - pf-rule:
  #         rule: "pass in quick inet proto tcp from { {{ allow_extra }} } to port 8888"
  #         before: "block in quick proto tcp to port 8888"
  #         if_set: "{{ allow_extra }}"
  class PfRule < Primitive
    PATH      = "/etc/pf.conf"
    TMP       = "/etc/pf.conf.beryl.tmp"
    BEGIN_TAG = "# >>> beryl >>>"
    END_TAG   = "# <<< beryl <<<"
    NAT_BEGIN = "# >>> beryl nat >>>"
    NAT_END   = "# <<< beryl nat <<<"
    # Mots-clés de début de section FILTRE : le bloc nat s'insère juste avant.
    FILTER_KW = /\A\s*(block|pass|match|antispoof)\b/

    def name : String
      "pf-rule"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      if params.has_key?("if_set") && (params["if_set"].as_s? || "").strip.empty?
        return StepResult.skipped("paramètre vide (if_set) — règle non demandée")
      end
      rule = required_string(params, "rule").strip
      state = string(params, "state") || "present"
      before_rule = string(params, "before").try(&.strip)
      nat = bool(params, "nat", default: false)
      begin_tag = nat ? NAT_BEGIN : BEGIN_TAG
      end_tag = nat ? NAT_END : END_TAG

      content = shell.exec("cat #{Process.quote(PATH)} 2>/dev/null", raise_on_error: false).stdout
      before, block, after, had_block = split_managed(content, begin_tag, end_tag)

      present = block.includes?(rule)
      case state
      when "present"
        if present
          return StepResult.skipped("règle pf déjà présente")
        end
        if before_rule && (idx = block.index(before_rule))
          block.insert(idx, rule)
        else
          block << rule
        end
        verb = "ajout"
      when "absent"
        unless present
          return StepResult.skipped("règle pf déjà absente")
        end
        block.reject! { |l| l == rule }
        verb = "retrait"
      else
        raise MissingParam.new("`state` doit valoir present ou absent (reçu #{state.inspect}).")
      end

      msg = "pf#{nat ? " (nat)" : ""} : #{verb} « #{rule} »"
      return StepResult.applied("#{msg} (dry-run)") if dry_run

      new_content = rebuild(before, block, after, had_block, begin_tag, end_tag, nat)
      shell.write_file(TMP, new_content)
      # Valide la conf complète AVANT de la mettre en place (échec =
      # stop net, pf.conf courant intact).
      shell.exec("pfctl -nf #{Process.quote(TMP)}")
      shell.exec("mv #{Process.quote(TMP)} #{Process.quote(PATH)}")
      shell.exec("pfctl -f #{Process.quote(PATH)}")
      StepResult.applied(msg)
    end

    # Découpe le contenu en (avant, lignes du bloc, après, bloc_présent) pour
    # la paire de marqueurs donnée (bloc filtre OU bloc nat).
    private def split_managed(content : String, begin_tag : String, end_tag : String) : {Array(String), Array(String), Array(String), Bool}
      lines = content.empty? ? [] of String : content.lines.map(&.chomp)
      bi = lines.index(begin_tag)
      ei = lines.index(end_tag)
      if bi && ei && ei > bi
        before = lines[0...bi]
        block = lines[(bi + 1)...ei].reject(&.strip.empty?)
        after = lines[(ei + 1)..]
        {before, block, after, true}
      else
        {lines, [] of String, [] of String, false}
      end
    end

    # Reconstruit le fichier. Si le bloc est vide et n'existait pas, on ne
    # l'ajoute pas (pas de churn inutile). Un bloc nat NOUVEAU est inséré
    # AVANT la 1ʳᵉ règle filtre (ordre pf) ; sinon (filtre, ou bloc déjà
    # présent) il reste à sa place / en fin de fichier.
    private def rebuild(before : Array(String), block : Array(String), after : Array(String),
                        had_block : Bool, begin_tag : String, end_tag : String, nat : Bool) : String
      head, tail =
        if nat && !had_block
          idx = before.index { |l| l =~ FILTER_KW } || before.size
          {before[0...idx], before[idx..] + after}
        else
          {before, after}
        end
      String.build do |io|
        head.each { |l| io << l << '\n' }
        if !block.empty? || had_block
          io << begin_tag << '\n'
          block.each { |l| io << l << '\n' }
          io << end_tag << '\n'
        end
        tail.each { |l| io << l << '\n' }
      end
    end
  end

  Primitive.register(PfRule.new)
end
