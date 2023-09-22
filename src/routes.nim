import std/strutils
import std/uri

import prologue
import jwt

import ./controllers/[login,articles,errors,assets,groups,group_posts,home,oauth,api,votes]
import ./context

proc setApi*(): HandlerAsync =
  result = proc(ctx: Context) {.async.} =
    AppContext(ctx).api = true
    await switch(ctx)

proc ensureLoggedIn*(): HandlerAsync =
  result = proc(ctx: Context) {.async.} =
    if ctx.session.getOrDefault("email", "") != "":
      await switch(ctx)
      return

    if AppContext(ctx).login_bearer or AppContext(ctx).api:
      resp "Unauthorized", Http401
    else:
      resp redirect($ (parse_uri("/login") ? { "redirect_url": $ctx.request.url }), code = Http303)

proc init_routes*(app: Prologue) =
  app.addRoute("/.well-known/oauth-authorization-server", oauth.authorization_server, HttpGet)
  app.addRoute("/.well-known/oauth-authorization-server/auth", oauth.auth, HttpGet)
  app.addRoute("/.well-known/oauth-authorization-server/token", oauth.token, HttpPost)
  app.addRoute("/.well-known/disputatio/", api.get, HttpGet, middlewares = @[setApi()])
  app.addRoute("/.well-known/disputatio/", api.post, HttpPost, middlewares = @[setApi()])
  app.addRoute("/.well-known/disputatio/login", login.post_api, HttpPost, middlewares = @[setApi()])
  app.addRoute(re"^/.well-known/disputatio/(g|@)/$", groups.api_create, HttpPost, middlewares = @[])
  app.addRoute(re"^/.well-known/disputatio/(g:|@)(?P<groupguid>[^/]+)/info/$", groups.json_info, HttpGet, middlewares = @[setApi()])
  app.addRoute(re"^/.well-known/disputatio/(g:|@)(?P<groupguid>[^/]+)/join/$", groups.join, HttpPost, middlewares = @[setApi(), ensureLoggedIn()])
  app.addRoute(re"^/.well-known/disputatio/(g:|@)(?P<groupguid>[^/]+)/posts/$", group_posts.create, HttpPost, middlewares = @[setApi(), ensureLoggedIn()])
  app.addRoute(re"^/.well-known/disputatio/(g:|@)(?P<groupguid>[^/]+)/(a:)(?P<articleguid>[^/]+)/vote/$", votes.api_vote, HttpPost, middlewares = @[setApi(), ensureLoggedIn()])
  app.addRoute("/", home.index, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/logout", login.get_logout, HttpGet)
  app.addRoute("/logout", login.post_logout, HttpPost)
  app.addRoute("/login", login.get, HttpGet)
  app.addRoute("/login", login.post, HttpPost)
  app.addRoute("/login/{email}", login.get, HttpGet)
  app.addRoute("/login/{email}/{code}", login.get, HttpGet)
  app.addRoute(re"^/(g|@)/$", groups.create, HttpPost, middlewares = @[ensureLoggedIn()])
  app.addRoute(re"^/(g:|@)(?P<groupguid>[^/]+)/$", groups.show, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute(re"^/(g:|@)(?P<groupguid>[^/]+)/join/$", groups.join, HttpPost, middlewares = @[ensureLoggedIn()])
  app.addRoute(re"^/(g:|@)(?P<groupguid>[^/]+)/posts/$", group_posts.create, HttpPost, middlewares = @[ensureLoggedIn()])
  app.addRoute(re"^/(u:|~)(?P<userguid>[^/]+)/$", articles.index, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/", articles.create, HttpPost, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/{name}/", articles.show, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/{name}/", articles.update, HttpPost, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/{name}/edit", articles.edit, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/{name}/.json", articles.get_json, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/~{userguid}/{name}/.html", articles.get_html, HttpGet, middlewares = @[ensureLoggedIn()])
  app.addRoute("/assets/{path}$", assets.get, HttpGet)
  app.registerErrorHandler(Http404, go404)

