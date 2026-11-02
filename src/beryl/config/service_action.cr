require "yaml"

module Beryl::Config
  # Une action sur un service du serveur : `service <service> <action>`.
  # Sert à `freebsd.after_unlock:` (actions jouées par `beryl unlock`).
  record ServiceAction, service : String, action : String do
    # `onestart`… exclus : un service qui doit tourner est activé dans rc.conf.
    ACTIONS = %w[reload restart start stop]

    # Liste ORDONNÉE de `service: action` (l'ordre compte : la base avant le
    # site). Une table simple est acceptée aussi (ordre de lecture). `key` :
    # nom de la clé YAML, pour les messages. Forme, service ou action
    # invalide → InvalidServiceAction.
    def self.list_from_yaml(any : YAML::Any?, key : String) : Array(ServiceAction)
      return [] of ServiceAction unless any
      pairs = if list = any.as_a?
                list.flat_map { |item| item.as_h?.try(&.to_a) || raise InvalidServiceAction.new("`#{key}` attend des `service: action`, pas #{item.inspect}") }
              elsif h = any.as_h?
                h.to_a
              else
                raise InvalidServiceAction.new("`#{key}` attend une liste de `service: action`")
              end
      pairs.map do |svc, act|
        service = svc.as_s? || raise InvalidServiceAction.new("`#{key}` : nom de service invalide #{svc.inspect}")
        action = act.as_s? || ""
        unless service.matches?(/\A[A-Za-z0-9_.-]+\z/) && ACTIONS.includes?(action)
          raise InvalidServiceAction.new("`#{key}` : `#{service}: #{action}` invalide (actions : #{ACTIONS.join(", ")})")
        end
        new(service, action)
      end
    end
  end

  class InvalidServiceAction < Exception
  end
end
