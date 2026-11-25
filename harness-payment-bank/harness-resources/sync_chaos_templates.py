#!/usr/bin/env python3
"""Copy one ChaosHub onto another: faults, probes, actions, experiment templates.

Source is the live PnC hub. Destination is the workshop hub. Tokens that are
hardcoded in PnC stay hardcoded in workshop; they are copied in memory and
never written to disk or printed. Hub identity strings are rewritten.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

import yaml

JWT = re.compile(r"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+")

DROP = {
    "id",
    "accountID",
    "orgID",
    "projectID",
    "createdAt",
    "createdBy",
    "updatedAt",
    "updatedBy",
    "uniqueId",
    "parentUniqueId",
    "createdByUserDetails",
    "updatedByUserDetails",
    "correlationID",
    "gitDetails",
    "gitYaml",
    "storeType",
    "isEnterprise",
    "isRemoved",
    "editCounter",
    "template",
    "hubIdentity",
    "versionLabel",
    "cacheResponse",
    "entityValidityDetails",
    "internalIdentity",
    "internalIdentityWithRevision",
    "infras",
}

PROM_INPUT = {
    "name": "PROMETHEUSPROBEINPUTS_CONNECTORID",
    "value": "<+input>",
    "path": ".probeProperties.apmProbe.prometheusProbeInputs.connectorID",
    "category": "ProbeProperties",
    "type": "String",
    "required": True,
    "reference": {"kind": "Connector", "type": "Prometheus"},
}

EXPERIMENT_KEEP = {
    "name",
    "identity",
    "description",
    "tags",
    "kind",
    "apiVersion",
    "spec",
    "variables",
    "revision",
    "isDefault",
}


def env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(f"Set {name} before syncing chaos hubs.")
    return value


def redact(text):
    return JWT.sub("[redacted]", text)


def request(method, url, key, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"x-api-key": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def parse_json(raw):
    if not raw:
        return {}
    try:
        text = raw.decode("utf-8") if isinstance(raw, (bytes, bytearray)) else raw
        return json.loads(text)
    except json.JSONDecodeError:
        return {}


def unwrap(obj):
    if isinstance(obj, dict) and isinstance(obj.get("data"), dict):
        return obj["data"]
    return obj if isinstance(obj, dict) else {}


def rows(obj):
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        data = obj.get("data")
        if isinstance(data, list):
            return data
        if isinstance(data, dict) and isinstance(data.get("content"), list):
            return data["content"]
    return []


def missing(code, raw):
    if code in (404,):
        return True
    text = redact(raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw)).lower()
    return code == 500 and ("no documents" in text or "not found" in text)


def fail(kind, identity, verb, status, raw):
    detail = redact(raw.decode("utf-8", "replace") if isinstance(raw, (bytes, bytearray)) else str(raw))[:400]
    sys.exit(f"Could not {verb} {kind} {identity} (HTTP {status}). {detail}")


def rewrite(node, source_hub, dest_hub):
    if isinstance(node, dict):
        return {k: rewrite(v, source_hub, dest_hub) for k, v in node.items()}
    if isinstance(node, list):
        return [rewrite(v, source_hub, dest_hub) for v in node]
    if isinstance(node, str):
        return node.replace(source_hub, dest_hub)
    return node


def slim(body):
    return {k: v for k, v in body.items() if k not in DROP and v is not None}


def from_yaml(src):
    tpl = src.get("template")
    if isinstance(tpl, str) and tpl.strip():
        obj = yaml.safe_load(tpl)
        if isinstance(obj, dict):
            if src.get("inputs"):
                obj["inputs"] = src["inputs"]
            if src.get("revision") is not None and obj.get("revision") in (None, 0, "0"):
                obj["revision"] = src["revision"]
            if "isDefault" in src:
                obj["isDefault"] = src["isDefault"]
            return obj
    return slim(src)


def ensure_prom_input(body):
    apm = ((body.get("probeProperties") or {}).get("apmProbe") or {})
    connector = ((apm.get("prometheusProbeInputs") or {}).get("connectorID") or "")
    if apm.get("type") != "Prometheus" or connector != "<+input>":
        return body
    inputs = list(body.get("inputs") or [])
    if any(i.get("name") == "PROMETHEUSPROBEINPUTS_CONNECTORID" for i in inputs):
        return body
    inputs.append(dict(PROM_INPUT))
    body["inputs"] = inputs
    return body


def experiment_body(src):
    if isinstance(src.get("spec"), dict):
        return {k: src[k] for k in EXPERIMENT_KEEP if k in src}
    obj = from_yaml(src)
    return {k: obj[k] for k in EXPERIMENT_KEEP if k in obj}


def identities(items):
    out = []
    for item in items:
        ident = item.get("identity") or item.get("id")
        if ident:
            out.append(ident)
    return out


def main():
    key = os.environ.get("HARNESS_PLATFORM_API_KEY") or os.environ.get("HARNESS_API_KEY")
    if not key:
        sys.exit("Set HARNESS_PLATFORM_API_KEY or HARNESS_API_KEY before syncing chaos hubs.")
    account = env("HARNESS_ACCOUNT_ID")
    endpoint = env("HARNESS_ENDPOINT").rstrip("/")
    source_org = env("SOURCE_ORG_ID")
    source_hub = env("SOURCE_HUB")
    dest_org = env("HARNESS_ORG_ID")
    dest_hub = env("HARNESS_HUB_IDENTITY")
    base = f"{endpoint}/chaos/manager/api"

    def scope(org, hub, extra=None):
        q = {
            "accountIdentifier": account,
            "organizationIdentifier": org,
            "projectIdentifier": "",
            "hubIdentity": hub,
            "correlationID": str(uuid.uuid4()),
        }
        if extra:
            q.update(extra)
        return urllib.parse.urlencode(q)

    def get_item(path, identity, org, hub):
        url = f"{base}{path}/{urllib.parse.quote(identity)}?{scope(org, hub)}"
        return request("GET", url, key)

    def list_kind(path):
        found, page = [], 0
        while True:
            url = f"{base}{path}?{scope(source_org, source_hub, {'page': str(page), 'limit': '100'})}"
            code, raw = request("GET", url, key)
            if code != 200:
                fail("list", path, "read", code, raw)
            batch = identities(rows(parse_json(raw)))
            found.extend(batch)
            if len(batch) < 100:
                return found
            page += 1

    def upsert_json(kind, path, identity, body, default=True):
        extra = {"isDefault": "true"} if default else {}
        create_url = f"{base}{path}?{scope(dest_org, dest_hub, extra)}"
        update_url = f"{base}{path}/{urllib.parse.quote(identity)}?{scope(dest_org, dest_hub, extra)}"
        code, raw = get_item(path, identity, dest_org, dest_hub)
        live = unwrap(parse_json(raw)) if code == 200 else {}
        if live.get("revision") is not None:
            body["revision"] = live["revision"]
        body["hubRef"] = dest_hub
        body["isDefault"] = True
        if code == 200:
            status, raw = request("PUT", update_url, key, body)
            verb = "update"
        elif missing(code, raw):
            status, raw = request("POST", create_url, key, body)
            verb = "create"
        else:
            fail(kind, identity, "read dest", code, raw)
        if status not in (200, 201):
            fail(kind, identity, verb, status, raw)
        print(f"{verb} {kind} {identity}")

    print(f"copy {source_org}/{source_hub} -> {dest_org}/{dest_hub}")

    for identity in list_kind("/rest/faulttemplates"):
        code, raw = get_item("/rest/faulttemplates", identity, source_org, source_hub)
        if code != 200:
            fail("fault", identity, "read source", code, raw)
        parsed = parse_json(raw)
        body = parsed.get("fault") if isinstance(parsed.get("fault"), dict) else from_yaml(unwrap(parsed))
        body = rewrite(slim(body) if not parsed.get("fault") else slim(body), source_hub, dest_hub)
        dest_code, dest_raw = get_item("/rest/faulttemplates", identity, dest_org, dest_hub)
        dest = parse_json(dest_raw) if dest_code == 200 else {}
        dest_fault = dest.get("fault") if isinstance(dest.get("fault"), dict) else unwrap(dest)
        if dest_fault.get("revision"):
            body["revision"] = dest_fault["revision"]
        body["isDefault"] = True
        if dest_code == 200:
            status, raw = request(
                "PUT",
                f"{base}/rest/faulttemplates/{urllib.parse.quote(identity)}?{scope(dest_org, dest_hub)}",
                key,
                body,
            )
            verb = "update"
        elif missing(dest_code, dest_raw):
            status, raw = request("POST", f"{base}/rest/faulttemplates?{scope(dest_org, dest_hub)}", key, body)
            verb = "create"
        else:
            fail("fault", identity, "read dest", dest_code, dest_raw)
        if status not in (200, 201):
            fail("fault", identity, verb, status, raw)
        print(f"{verb} fault {identity}")

    for identity in list_kind("/rest/templates/probes"):
        code, raw = get_item("/rest/templates/probes", identity, source_org, source_hub)
        if code != 200:
            fail("probe", identity, "read source", code, raw)
        body = ensure_prom_input(rewrite(from_yaml(unwrap(parse_json(raw))), source_hub, dest_hub))
        upsert_json("probe", "/rest/templates/probes", identity, body)

    for identity in list_kind("/rest/templates/actions"):
        code, raw = get_item("/rest/templates/actions", identity, source_org, source_hub)
        if code != 200:
            fail("action", identity, "read source", code, raw)
        body = rewrite(from_yaml(unwrap(parse_json(raw))), source_hub, dest_hub)
        upsert_json("action", "/rest/templates/actions", identity, body)

    for identity in list_kind("/rest/experimenttemplates"):
        code, raw = get_item("/rest/experimenttemplates", identity, source_org, source_hub)
        if code != 200:
            fail("experiment", identity, "read source", code, raw)
        obj = rewrite(experiment_body(unwrap(parse_json(raw))), source_hub, dest_hub)
        dest_code, dest_raw = get_item("/rest/experimenttemplates", identity, dest_org, dest_hub)
        dest = unwrap(parse_json(dest_raw)) if dest_code == 200 else {}
        if dest.get("revision"):
            obj["revision"] = dest["revision"]
        obj["isDefault"] = True
        payload = {"manifest": json.dumps(obj, separators=(",", ":"), ensure_ascii=False)}
        if dest_code == 200:
            status, raw = request(
                "PUT",
                f"{base}/rest/experimenttemplates/{urllib.parse.quote(identity)}?{scope(dest_org, dest_hub)}",
                key,
                payload,
            )
            verb = "update"
        elif missing(dest_code, dest_raw):
            status, raw = request(
                "POST",
                f"{base}/rest/experimenttemplates?{scope(dest_org, dest_hub)}",
                key,
                payload,
            )
            verb = "create"
        else:
            fail("experiment", identity, "read dest", dest_code, dest_raw)
        if status not in (200, 201):
            fail("experiment", identity, verb, status, raw)
        print(f"{verb} experiment {identity}")


if __name__ == "__main__":
    main()
