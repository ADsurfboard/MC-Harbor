PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS messages(
 a TEXT NOT NULL, b TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 kind TEXT NOT NULL, text TEXT NOT NULL, invite TEXT NOT NULL DEFAULT '', created REAL NOT NULL, expires REAL NOT NULL,
 PRIMARY KEY(a,b,id), FOREIGN KEY(a,b) REFERENCES friendships(a,b) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS messages_time ON messages(a,b,created DESC);
CREATE INDEX IF NOT EXISTS messages_expiry ON messages(expires);
