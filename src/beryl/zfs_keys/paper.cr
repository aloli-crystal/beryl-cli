require "qr-code"
require "file_utils"
require "../zfs_keys"

module Beryl::ZfsKeys
  # Séquestre papier d'une clé ZFS : un PDF imprimable par serveur, à garder
  # hors du poste (coffre physique, enveloppe scellée). Il doit suffire à
  # déverrouiller le serveur SANS beryl ni le poste de l'opérateur : la clé
  # en clair, la procédure `zpool`/`zfs` à la main, et un QR code qui porte
  # la commande de déverrouillage complète (clé comprise) pour la coller
  # sans faute de frappe.
  #
  # Chaîne : AsciiDoc généré ici (pur) + QR codes en SVG (shard `qr-code`),
  # convertis par le binaire `asciicrystal-pdf` dans un dossier temporaire
  # 0700 ; le PDF (0600) est ensuite renommé à sa place, le dossier
  # temporaire (AsciiDoc et SVG, qui contiennent la clé) supprimé.
  module Paper
    # Convertisseur AsciiDoc → PDF par défaut (cherché dans le PATH) ;
    # `keys_paper.converter` de la config ou `--converter` le remplacent.
    DEFAULT_CONVERTER = "asciicrystal-pdf"

    # Fichiers intermédiaires, relatifs au dossier temporaire.
    QR_UNLOCK = "qr-unlock.svg"
    QR_DOCS   = "qr-docs.svg"

    class Error < Beryl::Encryption::Error
    end

    # Une unité chiffrée à déverrouiller : pool data (`import` vrai : il
    # faut d'abord l'importer) ou encryptionroot du zroot (déjà importé),
    # avec ses points de montage.
    record Unit, name : String, import : Bool, mountpoints : Array(String)

    # Tout ce que porte la feuille.
    record Sheet,
      account : String,
      fqdn : String,
      host_ref : String,
      var : String,
      units : Array(Unit),
      hex : String,
      edited_at : Time,
      docs_url : String?

    # Commande de déverrouillage en UNE ligne (contenu du QR code) : `sh -c`
    # pour marcher aussi sous csh, `printf %s` (pas de retour à la ligne :
    # ZFS lit exactement 64 caractères). Un pool déjà importé fait échouer
    # son `zpool import` sans arrêter la suite. Pur.
    def self.unlock_one_liner(sheet : Sheet) : String
      steps = ["K=#{sheet.hex}"]
      sheet.units.select(&.import).each { |u| steps << "zpool import -N #{u.name}" }
      steps << "for d in #{sheet.units.map(&.name).join(" ")}; do printf %s $K | zfs load-key $d; done"
      steps << "zfs mount -a"
      "sh -c '#{steps.join("; ")}'"
    end

    # QR code (correction M) en SVG : un seul `<path>` (un carré par module
    # noir), marge de 4 modules exigée par la norme. Pur.
    def self.qr_svg(data : String) : String
      qr = QRCode.new(data, level: :m)
      n = qr.modules.size
      quiet = 4
      side = n + 2 * quiet
      d = String.build do |io|
        n.times do |r|
          n.times do |c|
            io << 'M' << (c + quiet) << ',' << (r + quiet) << "h1v1h-1z" if qr.checked?(r, c)
          end
        end
      end
      %(<?xml version="1.0" encoding="UTF-8"?>\n) +
        %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{side} #{side}" width="#{side * 8}" height="#{side * 8}" shape-rendering="crispEdges">) +
        %(<rect width="#{side}" height="#{side}" fill="#ffffff"/><path fill="#000000" d="#{d}"/></svg>\n)
    end

    # Document AsciiDoc de la feuille. `with_docs_qr` : un QR code du lien
    # beryl est fourni à côté. Pur.
    def self.adoc(sheet : Sheet, with_docs_qr : Bool = false) : String
      hex_lines = sheet.hex.chars.each_slice(32).map { |s| ZfsKeys.groups(s.join) }.join("\n")
      names = sheet.units.map(&.name)
      String.build do |io|
        io << "= Clé de chiffrement ZFS — " << sheet.fqdn << "\n"
        io << ":lang: fr\n:nofooter:\n:sectnums!:\n\n"
        io << "[CAUTION]\n====\n"
        io << "Document *SECRET* : quiconque le détient peut lire les données chiffrées de ce serveur. "
        io << "À garder sous séquestre (coffre physique, enveloppe scellée), hors du poste de l'administrateur. "
        io << "Ne pas photocopier, ne pas numériser, ne pas photographier.\n====\n\n"
        io << "[cols=\"1,2\"]\n|===\n"
        io << "| Société | " << sheet.account << "\n"
        io << "| Serveur | " << sheet.fqdn << "\n"
        io << "| Chiffré | " << sheet.units.map { |u| "`#{u.name}` (#{u.mountpoints.join(", ")})" }.join(" + ") << "\n"
        io << "| Édité le | " << sheet.edited_at.to_s("%d/%m/%Y à %H:%M") << "\n"
        io << "| Empreinte de la clé | `" << ZfsKeys.fingerprint(sheet.hex) << "`\n"
        io << "| Coffre beryl | section `[" << SECTION << "]`, variable `" << sheet.var << "`\n"
        io << "|===\n\n"

        io << "== Clé (64 caractères hexadécimaux)\n\n"
        io << "....\n" << hex_lines << "\n....\n\n"
        io << "Les espaces ne servent qu'à la lecture : la clé se tape SANS espaces. "
        io << "Pour vérifier une copie, les 16 premiers caractères de son SHA-256 donnent l'empreinte "
        io << "(FreeBSD : `sha256 -s <clé>` ; macOS, Linux : `printf %s <clé> | shasum -a 256`).\n\n"

        io << "== Déverrouiller à la main, sans beryl\n\n"
        io << "Sur le serveur, en root (console du fournisseur, ou ssh), après un redémarrage :\n\n"
        io << "[source,sh]\n----\n"
        sheet.units.select(&.import).each { |u| io << "zpool import -N " << u.name << "\n" }
        names.each { |n| io << "zfs load-key " << n << "\n" }
        io << "zfs mount -a\n----\n\n"
        io << "Chaque `zfs load-key` demande la clé (_Enter hex key_) : la taper sans espaces. "
        io << "`zpool import -N` importe le pool sans le monter ; un pool déjà importé le signale, ce n'est pas une erreur. "
        io << "`zfs mount -a` monte ensuite tous les systèmes de fichiers déchiffrés.\n\n"

        io << "=== Par le QR code\n\n"
        io << "Le QR code contient toute la commande, clé comprise, sur une seule ligne. "
        io << "Scannez-le, puis collez le texte dans la session root du serveur :\n\n"
        io << "image::" << QR_UNLOCK << "[QR code de déverrouillage,pdfwidth=65mm,align=center]\n\n"
        io << "Ce qu'il contient, présenté sur trois lignes (`<clé>` : la clé ci-dessus, sans espaces) :\n\n"
        io << "[source,sh]\n----\n"
        io << "sh -c 'K=<clé>; "
        sheet.units.select(&.import).each { |u| io << "zpool import -N " << u.name << "; " }
        io << "\n  for d in " << names.join(" ") << "; do printf %s $K | zfs load-key $d; done;\n  zfs mount -a'\n----\n\n"

        io << "== Avec beryl\n\n"
        io << "Depuis le poste de l'administrateur (clé lue dans le coffre de la société) :\n\n"
        io << "[source,sh]\n----\nberyl unlock " << sheet.host_ref << " --apply\n----\n\n"
        io << "Depuis ce papier, sur un autre poste : recopier la clé dans un fichier (`chmod 0400`), puis :\n\n"
        io << "[source,sh]\n----\nberyl unlock " << sheet.host_ref << " --key-file <fichier> --apply\n----\n\n"
        io << "beryl affiche l'empreinte de la clé utilisée : elle doit être celle de cette feuille. "
        io << "Détruire le fichier ensuite.\n\n"

        io << "== Logiciel beryl\n\n"
        if url = sheet.docs_url
          io << "Documentation et téléchargement : " << url << "\n\n"
          io << "image::" << QR_DOCS << "[QR code du lien beryl,pdfwidth=35mm,align=center]\n" if with_docs_qr
        else
          io << "Lien non configuré (réglage `keys_paper.docs_url` de la configuration beryl).\n"
        end
      end
    end

    # Nom du PDF dans le dossier de sortie.
    def self.pdf_name(fqdn : String) : String
      "#{fqdn}-cle-zfs.pdf"
    end

    # Produit le PDF `out_path` (0600). Refuse un fichier déjà présent.
    # Intermédiaires dans un dossier 0700 voisin, supprimé dans tous les
    # cas. `converter` : binaire asciicrystal-pdf (ou compatible : `-o`,
    # `-n` pour ne pas ouvrir le PDF, `-N` pour ignorer la configuration
    # de l'utilisateur).
    def self.write_pdf(sheet : Sheet, out_path : String, converter : String = DEFAULT_CONVERTER) : Nil
      raise Error.new("#{out_path} existe déjà — refus d'écraser (supprimez-le ou choisissez un autre dossier)") if File.exists?(out_path)
      dir = File.dirname(out_path)
      tmp = File.join(dir, ".beryl-keys-#{Random::Secure.hex(6)}")
      Dir.mkdir(tmp, 0o700)
      begin
        File.chmod(tmp, 0o700)
        write_secret(File.join(tmp, QR_UNLOCK), qr_svg(unlock_one_liner(sheet)))
        docs_qr = false
        if url = sheet.docs_url
          write_secret(File.join(tmp, QR_DOCS), qr_svg(url))
          docs_qr = true
        end
        adoc_path = File.join(tmp, "cle.adoc")
        pdf_tmp = File.join(tmp, "cle.pdf")
        write_secret(adoc_path, adoc(sheet, docs_qr))
        err = IO::Memory.new
        status = begin
          Process.run(converter, ["-N", "-n", "-o", pdf_tmp, adoc_path], output: err, error: err, chdir: tmp)
        rescue ex : File::NotFoundError | IO::Error
          raise Error.new("convertisseur #{converter} introuvable (#{ex.message}) : installez asciicrystal-pdf, ou `--converter <chemin>`")
        end
        unless status.success? && File.exists?(pdf_tmp)
          raise Error.new("#{converter} a échoué (exit=#{status.exit_code}) : #{err.to_s.strip.lines.last(5).join(" | ")}")
        end
        File.chmod(pdf_tmp, 0o600)
        raise Error.new("#{out_path} apparu pendant la conversion — refus d'écraser") if File.exists?(out_path)
        File.rename(pdf_tmp, out_path)
      ensure
        FileUtils.rm_rf(tmp)
      end
    end

    private def self.write_secret(path : String, content : String) : Nil
      File.open(path, "w", perm: 0o600) { |f| f.print(content) }
    end
  end
end
