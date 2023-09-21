import std/uri
import std/strformat
import std/strutils
import std/options
import std/cgi
import std/times
import std/json
import smtp
import nauthy
import jwt

import ../utils/parse_port
import ../context
import ../db/users
import ../views/[layout, login_form, login_totp, logout_form]

import prologue

proc send_email(server: SmtpConf, sender, recipient: string, msg: string) =
  if server.host == "":
    echo &"No SMTP configured, failed to send e-mail:\nMAIL FROM: {sender}\nRCPT TO: {recipient}\n{msg}"
    return

  echo &"Connecting to {server.host}"
  let (smtp_server, smtp_port) = parse_addr_and_port(server.host, 25)

  let tls = server.tls == "tls" or (server.tls == "auto" and int(smtp_port) == 465)
  let starttls = (not tls) and server.tls != "none"

  var smtpConn = newSmtp(use_ssl = tls)
  smtpConn.connect(smtp_server, smtp_port)
  if starttls:
    smtpConn.starttls()
  if server.user != "":
    smtpConn.auth(server.user, server.pass)
  defer: smtpConn.close()
  smtpConn.sendMail(sender, @[recipient], msg)

proc send_code(ctx: AppContext, email, code: string, url: uri.Uri) =
  send_email(ctx.smtp, ctx.sender, email, $createMessage(
    &"Your {url.hostname} login code: {code}",
    &"To log-in to {url.hostname}, please click the following link:\n\n" &
    &"\t{url}\n\n" &
    &"Then enter the following code:\n\n" &
    &"\t{code}\n\n" &
    &"-- \n" &
    &"{url.hostname}\n" &
    &"Please do not reply to this automated message",
    @[email], @[],
    @[
      ("X-Login-URL", $(url / code)),
      ("X-Login-Code", code)
    ]))

proc send_code_api(ctx: AppContext, email, code: string) =
  let link_url = ctx.getFormParamsOption("email_url_template").get("").replace("{code}", code)
  let email_subject = ctx.getFormParamsOption("email_subject_template").get(
    "Your login code: {code}"
  ).replace("{code}", code)
  let email_body = ctx.getFormParamsOption("email_body_template").get(
    "The log-in code is:\n\n\t{code}\n\n-- \nPlease do not reply to this automated message.\n"
  ).replace("{code}", code).replace("{url}", link_url).replace("\r\n", "\n").replace("\n", "\r\n")

  send_email(ctx.smtp, ctx.sender, email, $createMessage(
    email_subject, email_body,
    @[email], @[],
    @[
      ("X-Login-URL", link_url),
      ("X-Login-Code", code)
    ]))

proc get*(ctx: Context) {.async, gcsafe.} =
  let db = AppContext(ctx).db
  let redirect_url = ctx.getQueryParamsOption("redirect_url").get("")
  let email = ctx.getPathParams("email", "")
  let code = ctx.getPathParams("code", "")
  let email_hash = hash_email(email)
  let user = db[].get_user(email_hash)

  # No email: provide login form to ask for email
  if email == "" or user.is_none():
    resp ctx.layout(login_form(redirect_url), title = "Login")
    return

  let totp_url = user.get().get_email(email_hash).get().totp_url
  let totp = otpFromUri(totp_url).totp

  # If it corresponds to the current user, show the TOTP URL
  if user.is_some:
    let current_user = user.get().get_email(hash_email(ctx.session.getOrDefault("email", "")))
    if current_user.is_some():
      resp ctx.layout(login_totp_ok(totp_url) & login_totp(email, code, redirect_url), title = "TOTP")
      return

  resp ctx.layout(login_totp(email, code, redirect_url), title = "Login")

proc post(ctx: AppContext, api: bool) {.async, gcsafe.} =
  var totp: Totp
  let db = ctx.db
  let redirect_url = ctx.getFormParamsOption("redirect_url").get("")
  let email = ctx.getFormParamsOption("email").get()
  let email_hash = hash_email(email)
  let otp = ctx.getFormParamsOption("otp")
  let user = db[].get_user(email_hash)

  # No code provided or the user does not exists
  if otp.is_none() or user.is_none():
    # If user does not exists, create totp secret and send email with code
    if user.is_none():
      totp = gen_totp(ctx.request.hostName, email)
      discard db[].create_user(email_hash, totp.build_uri())
    else:
      let totp_url = user.get().get_email(email_hash).get().totp_url
      totp = otpFromUri(totp_url).totp

    # Send code via e-mail
    let code = totp.now()
    echo &"TOTP code for {email}: {code}"

    if api:
      send_code_api(ctx, email, code)
      resp json_response(%*{ "otp_sent": true })
    else:
      var url = ctx.request.url / email
      url.hostname = ctx.request.headers["host", 0]
      url.scheme = if ctx.request.secure: "https" else: "http"
      send_code(ctx, email, code, url)
      resp redirect($ (parse_uri("/login/" & email.encodeUrl()) ? { "redirect_url": redirect_url }))
    return

  # code provided, check with OTP secret and store user in session
  # if user email has not been validated, mark as valid and provide OTP
  # secret URI

  let totp_url = user.get().get_email(email_hash).get().totp_url
  if not validate_totp(totp_url, otp.get, 10*60):
    if api:
      resp json_response(%*{ "otp_sent": false, "otp_valid": false })
    else:
      resp ctx.layout(login_form(redirect_url), title = "Retry Login")
    return

  var pod_url = ctx.request.url / email
  pod_url.hostname = ctx.request.headers["host", 0]
  pod_url.scheme = if ctx.request.secure: "https" else: "http"
  pod_url.path = "/"
  db[].ensure_user_in_pod(user.get().id, $pod_url, email_hash)

  db[].user_email_mark_valid(email_hash)

  if api:
    var token = toJWT(%*{
      "header": {
        "alg": "HS256",
        "typ": "JWT"
      },
      "claims": {
        "userId": %email,
      }
    })
    token.sign(ctx.secretkey)

    resp json_response(%*{ "otp_sent": false, "otp_valid": true, "token": % $token })
    return

  ctx.session["email"] = email

  if redirect_url != "":
    resp redirect(redirect_url)
    return

  resp ctx.layout(login_totp_ok(totp_url), title = "Login succeeded")

proc post*(ctx: Context) {.async, gcsafe.} =
  await post(AppContext(ctx), api = false)

proc post_api*(ctx: Context) {.async, gcsafe.} =
  await post(AppContext(ctx), api = true)

proc get_logout*(ctx: Context) {.async, gcsafe.} =
  resp ctx.layout(logout_form(), title = "Logout")

proc post_logout*(ctx: Context) {.async, gcsafe.} =
  ctx.session.del("email")
  resp redirect("/")
