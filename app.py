import os
from flask import Flask, jsonify, render_template_string

app = Flask(__name__)

VERSION = os.getenv("APP_VERSION", "v1")
SLOT = os.getenv("DEPLOYMENT_SLOT", "blue")
COMMIT = os.getenv("GIT_COMMIT", "local")
FAIL_READINESS = os.getenv("FAIL_READINESS", "false").lower() == "true"

@app.get("/")
def index():
    return render_template_string("""
    <!doctype html>
    <html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Blue-Green Deployment Lab — Release 2</title>
        <style>
            body {
                background: #13151f;
                color: #e9ecee;
                font-family: Arial, sans-serif;
                padding: 60px 24px;
            }
            main { max-width: 700px; margin: auto; }
            .card {
                background: #202433;
                padding: 32px;
                border-radius: 16px;
                border-top: 5px solid {{ accent }};
            }
            h1 { font-size: 32px; }
            p { font-size: 18px; line-height: 1.6; }
            a { color: #8dcfff; }
        </style>
    </head>
    <body>
        <main>
            <h1>Blue-Green Deployment Lab</h1>
            <div class="card">
                <p>Application version: <strong>{{ version }}</strong></p>
                <p>Deployment slot: <strong>{{ slot }}</strong></p>
                <p>Commit: <strong>{{ commit }}</strong></p>
                <p>Built by Chirag Deviputra</p>
            </div>
            <p><a href="/health">Health check</a> |
               <a href="/ready">Readiness check</a> |
               <a href="/version">Release details</a></p>
        </main>
    </body>
    </html>
    """, version=VERSION, slot=SLOT, commit=COMMIT,
         accent="#46d190" if SLOT == "green" else "#51a8ff")

@app.get("/health")
def health():
    return jsonify(status="healthy")

@app.get("/ready")
def ready():
    if FAIL_READINESS:
        return jsonify(status="not_ready"), 503
    return jsonify(status="ready")

@app.get("/version")
def version():
    return jsonify(version=VERSION, slot=SLOT, commit=COMMIT)

@app.get("/api/message")
def message():
    return jsonify(message="Deployment lab is working", version=VERSION)
