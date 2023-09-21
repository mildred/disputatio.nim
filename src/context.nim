import std/strformat
import std/strutils
import prologue
import easy_sqlite3
import jwt

import ./db/users

export hash_email

proc current_user_guid*(ctx: Context): string =
  hash_email(ctx.session["email"])

type SmtpConf* = tuple
  host: string
  user: string
  pass: string
  tls:  string

type AppContext* = ref object of Context
  db*: ref Database
  db_file*: string
  smtp*: SmtpConf
  sender*: string
  assets_dir*: string
  secretkey*: string
  api*: bool
  login_bearer*: bool

proc contextMiddleware*(db_file, assets_dir: string, smtp: SmtpConf, sender, secretkey: string): HandlerAsync =
  result = proc(ctx: Context) {.async.} =
    let ctx = AppContext(ctx)
    ctx.api = false
    ctx.login_bearer = false
    ctx.secretkey = secretkey
    ctx.assets_dir = assets_dir
    ctx.smtp = smtp
    ctx.sender = sender
    if ctx.sender == "":
      ctx.sender = "no-reply@{ctx.request.hostName}"
    if ctx.db == nil:
      ctx.db_file = db_file
      ctx.db = new(Database)
      ctx.db[] = init_database(db_file)
    await switch(ctx)

proc contextLogin*(): HandlerAsync =
  result = proc(ctx: Context) {.async.} =
    let ctx = AppContext(ctx)
    for auth in ctx.request.getHeaderOrDefault("Authorization"):
      if ctx.session.getOrDefault("email", "") != "": break
      let words = auth.split(" ")
      if words.len == 2 and words[0].toLowerAscii() == "bearer":
        ctx.login_bearer = true
        # echo "token"
        # echo words[1]
        let token = words[1].toJWT()
        try:
          if token.verify(ctx.secretkey, HS256):
            # echo "token verified"
            ctx.session["email"] = $token.claims["userId"].node.str
            break
        except InvalidToken:
          # echo "invalid token"
          discard
    await switch(ctx)
