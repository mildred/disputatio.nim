const schema* = @["""
PRAGMA user_version = 10""", """
CREATE TABLE "user" (
            id            INTEGER PRIMARY KEY NOT NULL
          )""", """
CREATE TABLE "user_email" (
            user_id       INTEGER NOT NULL,
            email_hash    TEXT NOT NULL,
            totp_url      TEXT,
            valid         BOOLEAN DEFAULT FALSE,
            PRIMARY KEY (user_id, email_hash),
            FOREIGN KEY (user_id) REFERENCES "user" (id),
            CONSTRAINT email_hash_unique UNIQUE (email_hash)
          )""", """
CREATE TABLE "paragraph" (
            id          INTEGER PRIMARY KEY NOT NULL,
            guid        TEXT NOT NULL,
            text        TEXT NOT NULL,
            style       TEXT NOT NULL DEFAULT '',
            CONSTRAINT guid_unique UNIQUE (guid)
          )""", """
CREATE TABLE "patch" (
            id          INTEGER PRIMARY KEY NOT NULL,
            guid        TEXT NOT NULL,
            parent_id   INTEGER,
            FOREIGN KEY (parent_id) REFERENCES "patch" (id),
            CONSTRAINT guid_unique UNIQUE (guid)
          )""", """
CREATE TABLE "patch_item" (
            patch_id     INTEGER NOT NULL,
            paragraph_id INTEGER NOT NULL,
            rank         INTEGER NOT NULL,
            PRIMARY KEY (patch_id, paragraph_id),
            FOREIGN KEY (patch_id) REFERENCES "patch" (id),
            FOREIGN KEY (paragraph_id) REFERENCES "paragraph" (id)
          )""", """
CREATE TABLE "subject" (
            id          INTEGER PRIMARY KEY,
            guid        TEXT NOT NULL,
            name        TEXT NOT NULL,
            CONSTRAINT guid_unique UNIQUE (guid)
          )""", """
CREATE TABLE "type" (
            type        TEXT PRIMARY KEY NOT NULL
          )""", """
CREATE TABLE "group_member_item" (
            id                 INTEGER PRIMARY KEY NOT NULL,
            group_member_id    INTEGER NOT NULL,
            pod_url            TEXT,
            local_user_id      TEXT,
            FOREIGN KEY (group_member_id) REFERENCES "group_member" (id)
          )""", """
CREATE TABLE "group_item" (
            id                       INTEGER PRIMARY KEY NOT NULL,
            guid                     TEXT NOT NULL,
            root_guid                TEXT NOT NULL,             -- group root item
            parent_id                INTEGER DEFAULT NULL,      -- group parent item
            parent_guid              TEXT DEFAULT NULL,
            child_id                 INTEGER DEFAULT NULL,      -- child group item (if any)
            name                     TEXT NOT NULL,             -- group name
            seed_userdata            TEXT NOT NULL DEFAULT '',  -- seed for unique guid
            others_members_weight    REAL DEFAULT 0,            -- weight of unlisted members
            group_type               INTEGER NOT NULL,
                        -- 0: private, only listed members can read
                        -- 1: private, anyone can be invited with link
                        -- 3: public, anyone can read and group is discoverable
            moderation_default_score REAL DEFAULT 0,            -- score for unlisted member's articles

            FOREIGN KEY (root_guid) REFERENCES "group_item" (guid),
            FOREIGN KEY (parent_guid) REFERENCES "group_item" (guid),
            FOREIGN KEY (parent_id) REFERENCES "group_item" (id),
            CONSTRAINT guid_unique UNIQUE (guid)
          )""", """
CREATE TABLE "group_member" (
            id                 INTEGER PRIMARY KEY NOT NULL,
            local_id           INTEGER NOT NULL,        -- unique id within the group
            obsolete           BOOLEAN DEFAULT FALSE,   -- is the member obsolete (private data to pod)
            obsoleted_by       INTEGER DEFAULT NULL,    -- id that makes it obsolete (NULL: removed member)
            group_item_id      INTEGER NOT NULL,        -- group the member belongs to
            nickname           TEXT,                    -- member nickname
            weight             REAL NOT NULL DEFAULT 1, -- member weight within group
            user_id            INTEGER,                 -- user id for instance

            CONSTRAINT local_id_unique UNIQUE (local_id, group_item_id),
            FOREIGN KEY (obsoleted_by) REFERENCES "group_member" (id),
            FOREIGN KEY (group_item_id) REFERENCES "group_item" (id),
            FOREIGN KEY (user_id) REFERENCES "user" (id)
          )""", """
CREATE TABLE "user_pod" (
            id            INTEGER PRIMARY KEY NOT NULL,
            user_id       INTEGER NOT NULL,
            pod_url       TEXT NOT NULL,        -- public pod URL
            local_user_id TEXT NOT NULL,        -- public user id scoped by pod URL
            CONSTRAINT user_id_pod_url_unique UNIQUE (user_id, pod_url),
            FOREIGN KEY (user_id) REFERENCES "user" (id)
          )""", """
CREATE TABLE "article" (
            id                  INTEGER PRIMARY KEY NOT NULL,
            guid                TEXT NOT NULL,
            patch_id            INTEGER NOT NULL,
            patch_guid          TEXT NOT NULL,
            user_id             INTEGER,

            -- the article it modified
            mod_article_id      INTEGER DEFAULT NULL,
            mod_article_guid    INTEGER DEFAULT NULL,

            -- the item replying to, may be NULL
            reply_guid          TEXT DEFAULT NULL,      -- object guid being replied to (article)
            reply_index         INTEGER DEFAULT NULL,   -- paragraph replied to within article

            -- author of the message
            -- the message is not published here, the group is only used to keep track of the author
            author_group_id     INTEGER NOT NULL,       -- author personal group
            author_group_guid   TEXT NOT NULL,
            author_member_id    INTEGER,                -- member local_id (optional)

            -- group the article belongs to (can be same as author_group)
            -- where the message is published. If the group is public (others readable) the reply is readable to anyone who has access to the original item
            group_id            INTEGER NOT NULL,
            group_guid          TEXT NOT NULL,
            group_member_id     INTEGER,                -- local_id of member (NULL if other)

            kind                TEXT,                   -- could be topic, comment, reaction, ...
            timestamp           REAL NOT NULL DEFAULT (julianday('now')),

            CONSTRAINT guid_unique UNIQUE (guid)
            FOREIGN KEY (mod_article_id) REFERENCES "article" (id),
            FOREIGN KEY (mod_article_guid) REFERENCES "article" (guid),
            FOREIGN KEY (patch_id) REFERENCES "patch" (id),
            FOREIGN KEY (user_id) REFERENCES "user" (id),
            FOREIGN KEY (author_group_id) REFERENCES "group_item" (id),
            FOREIGN KEY (author_group_guid) REFERENCES "group_item" (guid),
            FOREIGN KEY (group_id) REFERENCES "group_item" (id),
            FOREIGN KEY (group_guid) REFERENCES "group_item" (guid)
          )""", """
CREATE TABLE "vote" (
            id                      INTEGER PRIMARY KEY NOT NULL,
            guid                    TEXT NOT NULL,
            group_id                INTEGER NOT NULL,
            group_guid              TEXT NOT NULL,
            member_id               INTEGER NOT NULL,
            article_id              INTEGER NOT NULL,
            article_guid            TEXT NOT NULL,
            paragraph_rank          INTEGER,
            vote                    REAL NOT NULL,
            timestamp               REAL NOT NULL DEFAULT (julianday('now')),
            CONSTRAINT guid_unique UNIQUE (guid)
            FOREIGN KEY (group_id, group_guid) REFERENCES group_item (id, guid),
            FOREIGN KEY (article_id, article_guid) REFERENCES article (id, guid)
          )""", """
CREATE VIEW article_score (group_guid, article_id, article_guid, score) AS
          WITH
            votes_incl_default AS (
              SELECT  v.article_id, v.article_guid, g.root_guid, v.member_id,
                      IIF(m.weight < 0, 1, MIN(MAX(SUM(v.vote), -1), 1)) vote, m.weight
              FROM    vote v
                      JOIN group_item g ON v.group_id = g.id
                      JOIN group_member m ON (m.group_item_id, m.local_id) = (v.group_id, v.member_id)
              GROUP BY v.article_id, v.article_guid, g.root_guid, v.member_id, m.weight
              UNION ALL
              SELECT  a.id article_id, a.guid article_guid, g.root_guid, 0 member_id,
                      1 vote, g.moderation_default_score weight
              FROM    article a JOIN group_item g ON a.group_id = g.id
            )
          SELECT  v.root_guid, v.article_id, v.article_guid,
                  SUM(v.vote * v.weight) AS score
          FROM    votes_incl_default v
          GROUP BY v.root_guid, v.article_id, v.article_guid"""]

