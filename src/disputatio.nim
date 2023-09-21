import std/os
import std/parseopt
import std/strutils
import std/strformat
import prologue
import prologue/middlewares/sessions/signedcookiesession
from prologue/core/urandom import random_string

import ./db/migration
import ./utils/parse_port
import ./routes
import ./context

const version {.strdefine.}: string = "(no version information)"

const doc = ("""
Usage: disputatio [options]

Options:
  -h, --help            Print help
  --version             Print version
  --listen <addr>       Specify a different port [default: localhost:8080]
                        Specify sd=0 for first systemd socket activation
                        or specify sd=[NAME:]N
  --secretkey <key>     Secret key for HTTP sessions
  -d, --db <file>       Database file [default: ./disputatio.sqlite]
  --assets <dir>        Assets directory [default: ./assets/]
  --smtp <server>       SMTP server for sending e-mails
  --smtp-tls <tls>      TLS security (none, auto, tls, starttls)
  --smtp-user <user>    SMTP username
  --smtp-pass <pass>    SMTP password
  --sender <email>      Sending address for e-mails
""") & (when not defined(version): "" else: &"""

Version: {version}
""")


when isMainModule:
  when defined(version):
    echo &"Starting disputatio version {version}"
  else:
    echo "Starting disputatio"

  var address = "localhost"
  var port = Port(8080)
  var secretkey = ""
  var dbfile = "./disputatio.sqlite"
  var assets = "./assets/"
  var smtp: SmtpConf
  smtp.tls = "auto"
  var sender = ""

  const shortNoVal = {'h'}
  const longNoVal = @["help", "version"]

  for kind, key, val in getopt(shortNoVal = shortNoVal, longNoVal = longNoVal):
    case kind
    of cmdArgument:
      echo "Unknown argument " & key
      quit(1)
    of cmdLongOption, cmdShortOption:
      case key
      of "listen":
        let arg_fd      = parse_sd_socket_activation(val)
        (address, port) = parse_addr_and_port(val, 8080)

        if arg_fd != -1:
          echo "Unsupported systemd socket activation of file descriptor inheritance"
          echo "See: <https://github.com/ringabout/httpx/issues/12>"
          quit(1)

      of "secretkey": secretkey = val
      of "db":        dbfile = val
      of "assets":    assets = val
      of "smtp":      smtp.host = val
      of "smtp-tls":  smtp.tls = val
      of "smtp-user": smtp.user = val
      of "smtp-pass": smtp.pass = val
      of "sender":    sender = val
      of "help", "h":
        echo doc
        quit()
      of "version":
        echo version
        when defined(version):
          quit(0)
        else:
          quit(1)
      else:
        echo "Unknown argument: " & key & " " & val
        quit(1)
    of cmdEnd: assert(false) # cannot happen

  if secretkey.len == 0:
    secretkey = random_string(16).to_hex()
    echo "Using secret key: " & secretkey

  let settings = newSettings(address = address, port = port, secretkey = secretkey)

  let db = open_database(dbfile)
  discard db

  echo &"Use SMTP config {smtp.tls} {smtp.host} user={smtp.user}"

  var app = newApp(settings)
  app.use(contextMiddleware(dbfile, assets, smtp, sender, secretkey))
  app.use(sessionMiddleware(settings))
  app.use(contextLogin())
  init_routes(app)
  app.run(AppContext)
