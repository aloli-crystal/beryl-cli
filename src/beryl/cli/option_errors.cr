require "option_parser"

module Beryl::CLI
  # Code de sortie d'une ligne de commande mal formée (option inconnue,
  # valeur manquante).
  EXIT_BAD_OPTION = 2

  # Erreurs d'options de TOUTES les commandes : message clair qui renvoie à
  # l'aide de la commande, code 2. Sans cela, OptionParser lève une exception
  # que les commandes affichent en « erreur inattendue — OptionParser::… ».
  # Retourne le parser, pour s'écrire `handle_option_errors(parser).parse(args)`.
  def self.handle_option_errors(parser : OptionParser) : OptionParser
    parser.invalid_option do |flag|
      STDERR.puts "#{option_command(parser)} : option inconnue : #{flag} (voir #{option_command(parser)} --help)"
      exit EXIT_BAD_OPTION
    end
    parser.missing_option do |flag|
      STDERR.puts "#{option_command(parser)} : valeur manquante pour #{flag} (voir #{option_command(parser)} --help)"
      exit EXIT_BAD_OPTION
    end
    parser
  end

  # Nom de la commande tiré du banner, 1re ligne de l'aide (« USAGE : beryl
  # env migrate [--force] » → « beryl env migrate ») ; lu au moment de
  # l'erreur, une fois le banner posé.
  def self.option_command(parser : OptionParser) : String
    words = parser.to_s.lines.first?.to_s.split
    start = words.index("beryl") || return "beryl"
    command = words[(start + 1)..].take_while(&.matches?(/\A[a-z][a-z0-9-]*\z/))
    (["beryl"] + command).join(" ")
  end
end
