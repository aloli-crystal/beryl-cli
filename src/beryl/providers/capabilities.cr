module Beryl
  # Modules mixins qui matérialisent les *capabilities* déclarées par
  # un `Provider`. Un provider qui déclare `capabilities == [:dns]`
  # DOIT inclure `Beryl::DnsProvider` et implémenter ses méthodes ;
  # pareil pour `:compute` avec `Beryl::ComputeProvider`.
  #
  # Les sous-commandes beryl qui ont besoin d'une capability font :
  #
  #     provider = Beryl::Providers.find("ovh")
  #     unless provider.capable_of?(:dns)
  #       raise "OVH ne sait pas gérer le DNS"
  #     end
  #     dns = provider.as(Beryl::DnsProvider)
  #     dns.ensure_record(...)
  #
  # Le `as(...)` est sûr tant que `capabilities` est correctement
  # synchronisé avec les `include` du provider. Aucune magie : on
  # demande à la classe elle-même.

  # Capability `:dns` — gestion d'une zone DNS.
  #
  # Un provider qui l'implémente sait poser des records A/AAAA/CNAME,
  # rafraîchir la zone, poser un reverse sur une IP, et changer le
  # nom d'affichage côté panel (utile pour les serveurs dédiés OVH
  # qui ont un displayName distinct du service_name technique).
  #
  # Les exceptions `NotImplementedError` signalent qu'un appel a été
  # tenté sur un provider qui déclare la capability mais n'a pas
  # encore câblé la méthode — bug côté implémenteur, message clair
  # pour le diagnostiquer.
  module DnsProvider
    # Enregistre (ou met à jour) un record DNS. Idempotent : si le
    # record existe déjà avec la même valeur, no-op.
    #
    # `zone`       → nom de la zone (ex: "example.net")
    # `field_type` → type DNS ("A", "AAAA", "CNAME", "TXT"…)
    # `sub_domain` → sous-partie ("loulou" ou "" pour le root)
    # `target`     → valeur du record (IP, FQDN, …)
    abstract def ensure_record(zone : String, field_type : String, sub_domain : String, target : String) : Nil

    # Déclenche un refresh de la zone côté provider (nécessaire chez
    # OVH pour propager un record fraîchement ajouté).
    abstract def refresh_zone(zone : String) : Nil

    # Pose (ou met à jour) le reverse DNS d'une IP. `reverse` est un
    # FQDN (avec ou sans point final).
    abstract def set_reverse(ip : String, reverse : String) : Nil
  end

  # Capability `:compute` — hébergement de serveurs.
  #
  # Un provider qui l'implémente sait rebooter un serveur en rescue,
  # rebooter depuis le disque (« boot-hd »), lister ses clés SSH
  # enregistrées côté panel, et répondre à des méta-questions
  # (comment s'appelle ma machine, combien d'IPs, etc.).
  module ComputeProvider
    # Demande un reboot en rescue mode côté panel. Le provider pose
    # la clé SSH qu'il veut que beryl utilise pour se connecter.
    # Retourne un identifiant de task (numérique OVH, ou UUID
    # Scaleway) qu'on peut interroger avec `compute_task_status`.
    abstract def request_rescue(resource_id : String, ssh_key_ref : String) : String

    # Reboot depuis le disque (inverse de `request_rescue`). Même
    # signature de retour (task id).
    abstract def boot_from_disk(resource_id : String) : String

    # État d'une task (`"init"`, `"doing"`, `"done"`, `"ovhError"`…).
    # Convention : si la task est en état terminal de succès,
    # `task_done?` est vrai.
    abstract def compute_task_status(task_id : String) : String

    # Vrai si l'état `status` correspond à un terminal de succès
    # (`"done"`, `"completed"`, etc. selon les providers).
    abstract def compute_task_done?(status : String) : Bool
  end
end
