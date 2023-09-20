# Package

version       = "0.1.0"
author        = "Mildred Ki'Lya"
description   = "Moderated article database with possible federation"
license       = "AGPL-3.0-or-later"
srcDir        = "src"
bin           = @["disputatio"]


# Dependencies

requires "nim >= 1.6.6"

requires "prologue"
requires "https://github.com/mildred/easy_sqlite3#authorizer" # "easysqlite3"
requires "templates"
requires "nauthy"
requires "https://github.com/mildred/nim_qr.git#master"
requires "libp2p"
requires "canonicaljson"
requires "smtp"
requires "embedfs"
requires "nimsha2"
requires "jwt"
