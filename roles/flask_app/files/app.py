import os

import pymysql
from flask import Flask

app = Flask(__name__)


@app.route("/")
def index():
    conn = pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
    )
    with conn.cursor() as cur:
        cur.execute("SELECT text FROM messages")
        rows = cur.fetchall()
    conn.close()
    return "<h1>Data from the database</h1>" + "".join(f"<p>{r[0]}</p>" for r in rows)
