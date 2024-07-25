sql = """CREATE TABLE \"rel_avan\" (
  \"id\" INTEGER NOT NULL,
  \"nome\" TEXT,
  \"function\" TEXT,
  \"ordem\" INTEGER,
  \"rel_id\" INTEGER,
  \"definition\" TEXT,
  PRIMARY KEY(\"id\" AUTOINCREMENT),
  FOREIGN KEY(\"rel_id\") REFERENCES \"opc_cruz_rel\"(\"id\") ON DELETE CASCADE
);"""
sql = """CREATE TABLE \"rel_avan\" (
  \"id\" INTEGER NOT NULL,
  \"nome\" TEXT,
  \"function\" TEXT,
  \"ordem\" INTEGER,
  \"rel_id\" INTEGER,
  \"definition\" TEXT,
  PRIMARY KEY(\"id\" AUTOINCREMENT),
  FOREIGN KEY(\"rel_id\") REFERENCES \"opc_cruz_rel\"(\"id\") ON UPDATE SET NULL
);"""
sql = """CREATE TABLE \"rel_avan\" (
  \"id\" INTEGER NOT NULL,
  \"nome\" TEXT,
  \"function\" TEXT,
  \"ordem\" INTEGER,
  \"rel_id\" INTEGER,
  \"definition\" TEXT,
  PRIMARY KEY(\"id\" AUTOINCREMENT),
  FOREIGN KEY(\"rel_id\") REFERENCES \"opc_cruz_rel\"(\"id\") DEFERRABLE INITIALLY DEFERRED
);"""