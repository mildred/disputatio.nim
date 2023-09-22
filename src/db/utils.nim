import easy_sqlite3

proc get_julianday_sql(): tuple[time: float] {.importdb: "SELECT julianday('now')".}

proc get_julianday*(db: var Database): float =
  let julianday = db.get_julianday_sql()
  return julianday.time

proc get_julianday*(): float =
  var db = initDatabase(":memory:")
  result = db.get_julianday()
