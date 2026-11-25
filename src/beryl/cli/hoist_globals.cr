module Beryl::CLI
  # Options globales qui consomment l'argument suivant (forme « -c VALEUR »).
  GLOBAL_FLAGS_WITH_VALUE = {"-c", "--config", "--transport"}

  # Options globales ramenées en tête où qu'elles soient écrites
  # (`beryl sync g --apply --transport=direct -c ~/cfg`) ; forme `--opt=V`
  # ou `--opt V` / `-c V`. Aucune sous-commande ne réutilise ces noms
  # (`headscale-authkey` a `--headscale-config`). Rien n'est touché après
  # `--`. Pur.
  def self.hoist_globals(argv : Array(String)) : Array(String)
    moved = [] of String
    rest = [] of String
    i = 0
    while i < argv.size
      arg = argv[i]
      if arg == "--"
        rest.concat(argv[i..])
        break
      elsif arg.starts_with?("--transport=") || arg.starts_with?("--config=")
        moved << arg
      elsif GLOBAL_FLAGS_WITH_VALUE.includes?(arg) && i + 1 < argv.size
        moved << arg << argv[i + 1]
        i += 1
      else
        rest << arg
      end
      i += 1
    end
    moved + rest
  end
end
