require "ssh"

module Beryl::CLI
  # Pilotage d'un contrôleur RAID MATÉRIEL (MegaRAID, via `storcli`) DANS LE
  # RESCUE, avant bootstrap. Le rescue OVH ne fournit aucun outil contrôleur
  # → on récupère `storcli` depuis `storcli_url` (cf. `acme/infra-bin`), puis
  # on liste / détruit / reconfigure les volumes.
  #
  # DESTRUCTIF, mais en rescue (avant install) → 100 % rejouable. Après une
  # reconfiguration, on demande à l'opérateur de REBOOTER le rescue : les
  # disques se ré-énumèrent proprement, et un nouveau `beryl scan` voit le
  # résultat (JBOD = N disques bruts, ou le nouveau volume).
  #
  # Les helpers de parsing / construction de commandes sont PURS (testables) ;
  # l'orchestration prend une `SSH::Connection` (le rescue).
  module RaidController
    STORCLI = "/tmp/storcli64"

    # ── Helpers purs (testés) ───────────────────────────────────────────

    # Nombre de contrôleurs d'après `storcli show ctrlcount`
    # (« Controller Count = N »).
    def self.controller_count(output : String) : Int32
      if m = output.match(/Controller Count\s*=\s*(\d+)/)
        m[1].to_i
      else
        0
      end
    end

    # Slots des disques physiques d'après `storcli /cX/eall/sall show` :
    # la 1re colonne « EID:Slt » (ex. « 252:0 ») de chaque ligne disque.
    def self.parse_drive_slots(output : String) : Array(String)
      slots = [] of String
      output.each_line do |line|
        tok = line.strip.split(/\s+/).first?
        next unless tok
        slots << tok if tok =~ /^\d+:\d+$/
      end
      slots.uniq
    end

    # Traduit un niveau RAID numérique beryl en type storcli. Refuse les
    # niveaux non gérés par une carte matérielle (ex. 7 = raidz3, ZFS only).
    def self.raid_type(num : Int32) : String
      case num
      when  0 then "raid0"
      when  1 then "raid1"
      when  5 then "raid5"
      when  6 then "raid6"
      when 10 then "raid10"
      else
        raise ArgumentError.new("le contrôleur ne gère pas RAID #{num} (matériel : 0, 1, 5, 6, 10)")
      end
    end

    def self.create_vd_command(cid : Int32, raid_num : Int32, slots : Array(String)) : String
      cmd = "/c#{cid} add vd type=#{raid_type(raid_num)} drives=#{slots.join(",")}"
      # RAID 10 = miroirs (spans) stripés → storcli exige `pdperarray` (sinon
      # « Cannot create configuration with 1 span »). Chaque span = 1 miroir
      # de 2 disques → pdperarray=2 (4 disques → 2 spans, 6 → 3, etc.).
      cmd += " pdperarray=2" if raid_num == 10
      cmd
    end

    # Vérifie que le niveau RAID matériel est compatible avec le nombre de
    # disques. Lève `ArgumentError` (message exploitable) sinon — ainsi le
    # prompt re-demande AVANT toute opération destructive.
    def self.validate_drive_count!(raid_num : Int32, n : Int32) : Nil
      case raid_num
      when 0
        raise ArgumentError.new("RAID 0 exige au moins 1 disque") if n < 1
      when 1
        raise ArgumentError.new("RAID 1 = exactement 2 disques (#{n} sélectionnés) — pour #{n} disques en miroir, choisissez RAID 10") if n != 2
      when 5
        raise ArgumentError.new("RAID 5 exige au moins 3 disques (#{n} sélectionnés)") if n < 3
      when 6
        raise ArgumentError.new("RAID 6 exige au moins 4 disques (#{n} sélectionnés)") if n < 4
      when 10
        raise ArgumentError.new("RAID 10 exige au moins 4 disques en nombre PAIR (#{n} sélectionnés)") if n < 4 || n.odd?
      else
        raise ArgumentError.new("niveau RAID matériel non supporté : #{raid_num}")
      end
    end

    # Vrai si un contrôleur RAID matériel est présent sur le bus PCI — MÊME
    # en JBOD (la carte reste un « RAID bus controller » côté lspci). Permet
    # de proposer la (re)configuration même quand l'OS voit déjà des disques
    # bruts (ex. carte déjà basculée en JBOD → on peut vouloir recréer un VD).
    def self.parse_lspci_has_raid(output : String) : Bool
      output.lines.any? { |l| l =~ /raid bus controller/i || l =~ /megaraid/i }
    end

    def self.present?(conn : SSH::Connection) : Bool
      parse_lspci_has_raid(conn.exec("lspci 2>/dev/null", raise_on_error: false).stdout)
    end

    # ── Orchestration (rescue) ──────────────────────────────────────────

    # Télécharge storcli dans le rescue et vérifie qu'il s'exécute.
    def self.fetch(conn : SSH::Connection, url : String) : Bool
      dl = conn.exec(
        "curl -fsSL #{Process.quote(url)} -o #{STORCLI} && chmod +x #{STORCLI}",
        raise_on_error: false)
      return false unless dl.success?
      conn.exec("#{STORCLI} show ctrlcount", raise_on_error: false).success?
    end

    # Id du 1er contrôleur (on gère le cas mono-contrôleur, le commun) ; nil
    # si storcli n'en voit aucun.
    def self.controller_id(conn : SSH::Connection) : Int32?
      txt = conn.exec("#{STORCLI} show ctrlcount", raise_on_error: false).stdout
      controller_count(txt) > 0 ? 0 : nil
    end

    # Bascule le contrôleur en JBOD (les disques physiques deviennent des
    # disques bruts pour ZFS) : détruit les volumes puis active le JBOD.
    def self.to_jbod!(conn : SSH::Connection, cid : Int32) : Nil
      storcli(conn, "/c#{cid}/vall delete force") # supprime les VD (tolérant)
      storcli(conn, "/c#{cid} set jbod=on", must_succeed: true)
    end

    # Slots des disques physiques vus par le CONTRÔLEUR (storcli), quel que
    # soit ce que l'OS présente (volume = 1 disque OS, JBOD = N, « good » = 0).
    # → permet de valider le niveau RAID sur le VRAI nombre de disques.
    def self.drive_slots(conn : SSH::Connection, cid : Int32) : Array(String)
      parse_drive_slots(storcli(conn, "/c#{cid}/eall/sall show").stdout)
    end

    # Recrée un volume matériel à `raid_num` sur les `slots` fournis (comptés
    # en amont par `drive_slots`). Séquence robuste depuis N'IMPORTE QUEL état
    # (JBOD, volume, ou « Unconfigured Good ») : delete VD → JBOD off → forcer
    # « good » → add vd. Sans la remise en « good » : « resources already in use ».
    def self.recreate_on!(conn : SSH::Connection, cid : Int32, slots : Array(String), raid_num : Int32) : Nil
      raise "aucun disque physique listé par storcli (/c#{cid}/eall/sall show)" if slots.empty?
      validate_drive_count!(raid_num, slots.size)
      storcli(conn, "/c#{cid}/vall delete force")        # supprime les VD (tolérant)
      storcli(conn, "/c#{cid} set jbod=off")             # désactive JBOD (tolérant)
      storcli(conn, "/c#{cid}/eall/sall set good force") # disques → Unconfigured Good (tolérant)
      storcli(conn, create_vd_command(cid, raid_num, slots), must_succeed: true)
    end

    # Exécute une commande storcli en l'AFFICHANT (transparence sur une
    # opération destructive + debug in vivo). Si `must_succeed`, lève avec la
    # sortie storcli en cas d'échec (code retour OU « Status = Failure »).
    private def self.storcli(conn : SSH::Connection, args : String, must_succeed : Bool = false) : SSH::Result
      STDERR.puts "    storcli #{args}"
      res = conn.exec("#{STORCLI} #{args}", raise_on_error: false)
      combined = "#{res.stdout}#{res.stderr}"
      if must_succeed && (!res.success? || combined.includes?("Status = Failure"))
        raise "storcli #{args} a échoué :\n#{combined.strip}"
      end
      res
    end
  end
end
