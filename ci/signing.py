#!/usr/bin/env python3
"""App Store signing for the cloud Mac build, through the App Store Connect API.

ONE long-lived Apple Distribution certificate (valid a year), kept in the repo
as ci/dist-cert.enc: its .p12 encrypted (AES-GCM) with a key derived from
the ASC_KEY_P8 secret, so only this workflow can open it. Copied from LifeOS
(cmoney0/lifeos ios/ci/signing.py) - both apps share one certificate while
they share one App Store Connect key. History (from LifeOS):
  - Xcode automatic signing wanted a development profile, which needs a
    registered device ("Your team has no devices").
  - A per-run certificate revoked after upload failed Apple's processing
    (ITMS-90721 Certificate Revoked, build 36) and mailed Colby every run.

  setup    open the stored certificate (or create + store one if missing,
           revoked or expiring), make sure each bundle has an active App
           Store profile "Lectures CI <target>" holding it, install both into a
           temp keychain; writes signing.env. Prints STORE_CHANGED when the
           workflow must commit dist-cert.enc.
  cleanup  removes the temp keychain (never revokes anything).

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_FILE, RUNNER_TEMP.
Needs: pip install pyjwt cryptography.
"""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLES = {"Lectures": "com.cmoney0.lectures", "LecturesWidgets": "com.cmoney0.lectures.widgets"}
TMP = pathlib.Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "signing"
KEYCHAIN = str(TMP / "ci.keychain-db")
# must match the password inside the shared dist-cert.enc .p12 (made by LifeOS CI)
KC_PASS = "lifeos-ci"


def token():
    key = pathlib.Path(os.environ["ASC_KEY_FILE"]).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, missing_ok=False):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", "Bearer " + token())
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if missing_ok and e.code == 404:
            return None
        sys.exit(f"App Store Connect {method} {path} -> {e.code}: {e.read().decode()[:800]}")


def sh(*args):
    subprocess.run(args, check=True)


STORE = pathlib.Path(__file__).with_name("dist-cert.enc")
PROFILE_DIRS = [pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles",
                pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]


def store_key():
    return hashlib.sha256(pathlib.Path(os.environ["ASC_KEY_FILE"]).read_bytes().strip()).digest()


def load_store():
    if not STORE.exists():
        return None
    try:
        raw = base64.b64decode(STORE.read_text())
        plain = AESGCM(store_key()).decrypt(raw[:12], raw[12:], None)
        return json.loads(plain)
    except Exception as e:  # wrong key (new ASC key) or damaged file: start over
        print(f"Stored certificate unreadable ({type(e).__name__}) - making a new one")
        return None


def save_store(data):
    nonce = os.urandom(12)
    STORE.write_text(base64.b64encode(nonce + AESGCM(store_key()).encrypt(nonce, json.dumps(data).encode(), None)).decode() + "\n")


def cert_usable(cert_id):
    got = call("GET", f"/certificates/{cert_id}", missing_ok=True)
    if not got:
        return False
    exp = got["data"]["attributes"].get("expirationDate") or ""
    try:
        left = time.mktime(time.strptime(exp[:19], "%Y-%m-%dT%H:%M:%S")) - time.time()
    except ValueError:
        left = 0
    return left > 14 * 86400


def new_certificate():
    key, csr = TMP / "dist.key", TMP / "dist.csr"
    sh("openssl", "genrsa", "-out", str(key), "2048")
    sh("openssl", "req", "-new", "-key", str(key), "-out", str(csr), "-subj", "/CN=Lectures CI/C=US")
    csr_b64 = "".join(l for l in csr.read_text().splitlines() if "CERTIFICATE REQUEST" not in l)
    cert = call("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": csr_b64}}})["data"]
    der, pem = TMP / "dist.cer", TMP / "dist.pem"
    der.write_bytes(base64.b64decode(cert["attributes"]["certificateContent"]))
    sh("openssl", "x509", "-inform", "DER", "-in", str(der), "-out", str(pem))
    p12 = TMP / "dist.p12"
    # -legacy: macOS's security tool can't read OpenSSL 3's default p12 cipher
    legacy = ["-legacy"] if b"OpenSSL 3" in subprocess.run(["openssl", "version"], capture_output=True).stdout else []
    sh("openssl", "pkcs12", "-export", *legacy, "-inkey", str(key), "-in", str(pem), "-out", str(p12), "-passout", "pass:" + KC_PASS)
    return {"certificate": cert["id"], "p12": base64.b64encode(p12.read_bytes()).decode()}


def install_p12(p12_b64):
    p12 = TMP / "dist.p12"
    p12.write_bytes(base64.b64decode(p12_b64))
    sh("security", "create-keychain", "-p", KC_PASS, KEYCHAIN)
    sh("security", "set-keychain-settings", "-lut", "21600", KEYCHAIN)
    sh("security", "unlock-keychain", "-p", KC_PASS, KEYCHAIN)
    sh("security", "import", str(p12), "-k", KEYCHAIN, "-P", KC_PASS, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", KC_PASS, KEYCHAIN)
    existing = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout.split()
    sh("security", "list-keychains", "-d", "user", "-s", KEYCHAIN, *[k.strip('"') for k in existing])


def bundle_id(target, ident):
    found = call("GET", f"/bundleIds?filter[identifier]={urllib.parse.quote(ident)}&limit=20")["data"]
    bundle = next((b for b in found if b["attributes"]["identifier"] == ident), None)
    if not bundle:
        # needs no capabilities, so the API can register it itself
        bundle = call("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": ident, "name": target, "platform": "IOS"}}})["data"]
    if not bundle:
        sys.exit(f"No App ID {ident} in the developer portal - create it first")
    return bundle["id"]


def profile_for(target, ident, cert_id, all_profiles):
    """Reuse the active 'Lectures CI <target>' profile holding our certificate, else replace it.
    The name must NOT start with "LifeOS CI " - LifeOS's own signing deletes those."""
    name = f"Lectures CI {target}"
    keep = None
    for prof in all_profiles:
        a = prof["attributes"]
        if a.get("name") != name:
            continue
        certs = [c["id"] for c in (prof.get("relationships", {}).get("certificates", {}).get("data") or [])]
        if keep is None and a.get("profileState") == "ACTIVE" and cert_id in certs:
            keep = prof
        else:
            call("DELETE", f"/profiles/{prof['id']}", missing_ok=True)
    if keep is None:
        keep = call("POST", "/profiles", {"data": {"type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id(target, ident)}},
                              "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    content = base64.b64decode(keep["attributes"]["profileContent"])
    for d in PROFILE_DIRS:
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{keep['attributes']['uuid']}.mobileprovision").write_bytes(content)
    return name


def setup():
    TMP.mkdir(parents=True, exist_ok=True)
    data = load_store()
    changed = False
    if not data or not cert_usable(data.get("certificate", "")):
        data = new_certificate()
        save_store(data)
        changed = True
    install_p12(data["p12"])
    all_profiles = call("GET", "/profiles?limit=200&include=certificates").get("data", [])
    env = []
    for target, ident in BUNDLES.items():
        env.append(f'PROFILE_{target}="{profile_for(target, ident, data["certificate"], all_profiles)}"')
        env.append(f'BUNDLE_{target}="{ident}"')
    (TMP / "signing.env").write_text("\n".join(env) + "\n")
    print("Signing ready:", ", ".join(env))
    if changed:
        print("STORE_CHANGED")
        (TMP / "store-changed").write_text("1")


def cleanup():
    subprocess.run(["security", "delete-keychain", KEYCHAIN])
    print("Keychain removed")


if __name__ == "__main__":
    {"setup": setup, "cleanup": cleanup}[sys.argv[1]]()
