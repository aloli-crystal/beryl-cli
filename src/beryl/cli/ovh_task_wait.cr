require "api-ovh/ovh_api"

# Attente d'une tâche de redémarrage OVH (`hardReboot`), commune à
# `beryl rescue` et `beryl boot-hd`.
#
# Délai : 15 min. Les ADV-3 (EPYC 4465P, carte ASRock) mettent 6 à 9 min à
# finir leur `hardReboot` (constaté le 23 oct. 2026, onze serveurs lancés
# ensemble) : avec 5 min, beryl abandonnait alors que le redémarrage
# aboutissait chez OVH.
#
# Refus « A reboot has already been requested » (HTTP 403) : un redémarrage
# du serveur est déjà en cours chez OVH (commande relancée trop tôt).
# `pending_reboot` retrouve sa tâche, pour l'attendre au lieu d'échouer.
module Beryl::CLI::OvhTaskWait
  extend self

  TIMEOUT       = 15.minutes
  POLL_INTERVAL = 10.seconds

  # Attend que `task` atteigne un état terminal. Une ligne `log_step` par
  # état (init, todo, doing…) avec le temps passé dans chacun. nil si la
  # tâche a abouti, sinon le message d'erreur (à lever par l'appelant).
  def wait(prefix : String, client : OvhApi::Client, service_name : String, task : OvhApi::Endpoints::Task,
           timeout : Time::Span = TIMEOUT, poll : Time::Span = POLL_INTERVAL) : String?
    deadline = Time.instant + timeout
    current = task
    while Time.instant < deadline
      return if current.success?
      if current.failed? || current.status == "cancelled"
        return "tâche OVH ##{current.id} (#{current.function}) terminée en #{current.status} — #{current.comment}"
      end
      current_status = current.status
      Beryl.log_step(prefix, "OVH : tâche ##{task.id} en #{current_status}") do
        while Time.instant < deadline
          sleep poll
          current = client.dedicated_servers.task(service_name, task.id)
          break if current.status != current_status
        end
      end
    end
    return if current.success?
    timeout_message(current, timeout)
  end

  # Délai dépassé : le redémarrage n'est pas perdu, il continue chez OVH. Pur.
  def timeout_message(task : OvhApi::Endpoints::Task, timeout : Time::Span) : String
    "tâche OVH ##{task.id} (#{task.function}) toujours en #{task.status} après #{timeout.total_minutes.to_i} min ; " \
    "le redémarrage continue chez OVH : relancez la même commande dans quelques minutes (elle reprend la tâche en cours)"
  end

  # Le refus d'OVH quand un redémarrage est déjà demandé. Pur.
  def already_requested?(ex : Exception) : Bool
    ex.is_a?(OvhApi::ApiError) && ex.http_status == 403 && ex.message.to_s.includes?("already been requested")
  end

  # Tâche `hardReboot` encore en cours sur le serveur (la plus récente), ou
  # nil si OVH n'en montre aucune.
  def pending_reboot(client : OvhApi::Client, service_name : String) : OvhApi::Endpoints::Task?
    {"doing", "todo", "init"}.each do |status|
      ids = client.dedicated_servers.tasks(service_name, function: "hardReboot", status: status)
      return client.dedicated_servers.task(service_name, ids.max) unless ids.empty?
    end
    nil
  end
end
