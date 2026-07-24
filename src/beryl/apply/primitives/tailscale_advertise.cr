require "../primitive"

module Beryl::Apply
  # Primitive `tailscale-advertise` : déclare un node du mesh comme EXIT-NODE
  # (route tout le trafic sortant des autres nodes) et/ou SUBNET-ROUTER
  # (annonce des CIDR d'un LAN à joindre). Utilise `tailscale set` (déclaratif,
  # ne re-join pas le mesh, complète `headscale-join`).
  #
  # Le forwarding IP (`ip-forward`) et le NAT (pf) sont à poser À PART (dans la
  # recette) : `tailscale set` ne fait que l'ANNONCE. Côté Headscale, la route
  # doit ensuite être approuvée (`headscale route enable` ou ACL autoApprovers).
  #
  #     - tailscale-advertise: { exit_node: true }                 # exit-node
  #     - tailscale-advertise: { routes: [192.168.1.0/24] }        # subnet-router
  class TailscaleAdvertise < Primitive
    EXIT_ROUTES = ["0.0.0.0/0", "::/0"]

    def name : String
      "tailscale-advertise"
    end

    def apply(shell : Shell, params : Hash(String, YAML::Any), dry_run : Bool, context : Context) : StepResult
      exit_node = bool(params, "exit_node", default: false)
      routes = string_array(params, "routes")
      if !exit_node && routes.empty?
        raise PrimitiveError.new("`tailscale-advertise` : préciser `exit_node: true` et/ou `routes: [<cidr>, …]`")
      end

      # Le node doit être connecté (headscale-join joué avant).
      unless shell.exec("tailscale status --json >/dev/null 2>&1", raise_on_error: false).success?
        return StepResult.failed("tailscaled non connecté au mesh — jouez `headscale-node` d'abord")
      end

      # Idempotence : toutes les routes voulues déjà dans les prefs annoncées.
      desired = routes + (exit_node ? EXIT_ROUTES : [] of String)
      prefs = shell.exec("tailscale debug prefs 2>/dev/null", raise_on_error: false).stdout
      if desired.all? { |cidr| prefs.includes?(%("#{cidr}")) }
        return StepResult.skipped("déjà annoncé : #{desired.join(", ")}")
      end

      args = ["tailscale", "set"]
      args << "--advertise-exit-node" if exit_node
      args << "--advertise-routes=#{routes.join(",")}" unless routes.empty?

      return StepResult.applied("annoncerait #{desired.join(", ")} (dry-run)") if dry_run

      res = shell.exec(args.join(' '), raise_on_error: false)
      unless res.success?
        return StepResult.failed("`tailscale set` échoue : #{res.stderr.strip.lines.last? || "code #{res.exit_code}"}")
      end
      StepResult.applied("annonce : #{desired.join(", ")} (à approuver côté Headscale)")
    end
  end

  Primitive.register(TailscaleAdvertise.new)
end
