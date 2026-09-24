class_name DlnaClient
extends Node

## Minimal DLNA control point: finds media servers on the LAN (SSDP) and
## lists their folders (ContentDirectory Browse). Playback needs nothing
## extra — items are plain HTTP URLs that GoZen/FFmpeg streams with range
## requests, so the player opens them like files.
##
## Discovery sends M-SEARCH from one socket per IPv4 interface: on Windows a
## multicast sent from a wildcard socket leaves through a single interface,
## which is often a VPN/Hyper-V/Bluetooth adapter rather than the LAN.
## Wire formats live in DlnaXml.

signal server_found(server: Dictionary)
signal discovery_finished

const SEARCH_TARGETS := [DlnaXml.MEDIA_SERVER_TYPE, DlnaXml.CONTENT_DIRECTORY_TYPE]
## Seconds to collect search responses. Devices answer within MX (2 s).
const DISCOVERY_WINDOW := 3.0
## M-SEARCH goes over UDP; repeat it once in case the first is dropped.
const RESEND_AFTER := 0.5
const HTTP_TIMEOUT := 8.0
const PAGE_SIZE := 200
## Upper bound per folder so a huge flat library can't stall the UI.
const MAX_ENTRIES := 5000

## Discovered servers: {"name", "udn", "location", "service_type", "control_url"}.
var servers: Array[Dictionary] = []

var _sockets: Array[PacketPeerUDP] = []
var _discover_left: float = 0.0
var _resend_left: float = 0.0
## Description URLs already fetched (or being fetched) this discovery.
var _seen_locations: Dictionary = {}


func is_discovering() -> bool:
	return not _sockets.is_empty()


## Forget known servers and search again. Results arrive via server_found.
func discover() -> void:
	_close_sockets()
	servers.clear()
	_seen_locations.clear()
	for address in _local_ipv4_addresses():
		var sock := PacketPeerUDP.new()
		if sock.bind(0, address) == OK:
			_sockets.append(sock)
	if _sockets.is_empty():
		var sock := PacketPeerUDP.new()
		if sock.bind(0) == OK:
			_sockets.append(sock)
	if _sockets.is_empty():
		push_warning("DlnaClient: no UDP socket could be bound for discovery.")
		discovery_finished.emit()
		return
	_send_searches()
	_discover_left = DISCOVERY_WINDOW
	_resend_left = RESEND_AFTER


func _process(delta: float) -> void:
	if _sockets.is_empty():
		return
	for sock in _sockets:
		while sock.get_available_packet_count() > 0:
			_on_ssdp_packet(sock.get_packet().get_string_from_utf8())
	if _resend_left > 0.0:
		_resend_left -= delta
		if _resend_left <= 0.0:
			_send_searches()
	_discover_left -= delta
	if _discover_left <= 0.0:
		_close_sockets()
		discovery_finished.emit()


func _exit_tree() -> void:
	_close_sockets()


## Direct children of `object_id` on `server`, all pages. Returns
## {"ok": true, "entries": Array} (see DlnaXml.parse_didl) or
## {"ok": false, "error": String}.
func browse(server: Dictionary, object_id: String = DlnaXml.ROOT_OBJECT_ID) -> Dictionary:
	var entries: Array = []
	var start := 0
	while entries.size() < MAX_ENTRIES:
		var body := DlnaXml.browse_body(server["service_type"], object_id, start, PAGE_SIZE)
		var resp := await _http(server["control_url"], DlnaXml.browse_headers(server["service_type"]),
				HTTPClient.METHOD_POST, body)
		if not resp["ok"] and resp["body"] == "":
			return {"ok": false, "error": resp["error"]}
		# A SOAP fault arrives as HTTP 500 with a useful body — parse either way.
		var page := DlnaXml.parse_browse_response(resp["body"])
		if not page["ok"]:
			return {"ok": false, "error": page["error"] if resp["ok"] else "%s: %s" % [resp["error"], page["error"]]}
		var got := DlnaXml.parse_didl(page["didl"])
		entries.append_array(got)
		start += page["returned"] if page["returned"] > 0 else got.size()
		if got.is_empty() or start >= page["total"]:
			break
	return {"ok": true, "entries": entries}


## Raw body of a GET (e.g. a thumbnail image); empty on any failure.
func fetch_bytes(url: String) -> PackedByteArray:
	var resp := await _http(url, PackedStringArray(), HTTPClient.METHOD_GET, "", false)
	return resp["bytes"] if resp["ok"] else PackedByteArray()


# --- discovery internals ---

func _send_searches() -> void:
	for sock in _sockets:
		sock.set_dest_address(DlnaXml.SSDP_ADDRESS, DlnaXml.SSDP_PORT)
		for st in SEARCH_TARGETS:
			sock.put_packet(DlnaXml.msearch(st).to_utf8_buffer())


func _on_ssdp_packet(packet: String) -> void:
	var msg := DlnaXml.parse_ssdp(packet)
	if msg.is_empty() or _seen_locations.has(msg["location"]):
		return
	_seen_locations[msg["location"]] = true
	_fetch_description(msg["location"])


func _fetch_description(location: String) -> void:
	var resp := await _http(location)
	if not resp["ok"]:
		push_warning("DlnaClient: %s: %s" % [location, resp["error"]])
		return
	var server := DlnaXml.parse_description(resp["body"], location)
	if server.is_empty():
		return  # a MediaServer without a ContentDirectory — nothing to browse
	server["location"] = location
	# One device can answer on several interfaces / for both search targets.
	for known in servers:
		if (server["udn"] != "" and known["udn"] == server["udn"]) \
				or known["control_url"] == server["control_url"]:
			return
	servers.append(server)
	server_found.emit(server)


func _close_sockets() -> void:
	for sock in _sockets:
		sock.close()
	_sockets.clear()


static func _local_ipv4_addresses() -> Array[String]:
	var out: Array[String] = []
	for iface in IP.get_local_interfaces():
		for address in iface.get("addresses", []):
			var a := String(address)
			if a.is_valid_ip_address() and not a.contains(":") \
					and not a.begins_with("127.") and not a.begins_with("169.254."):
				out.append(a)
	return out


# --- HTTP ---

## One request with a timeout. {"ok", "code", "body", "bytes", "error"};
## "ok" means a 2xx response, "bytes" is the raw body of one. `as_text`
## false skips decoding "body" (binary responses aren't UTF-8).
func _http(url: String, headers: PackedStringArray = PackedStringArray(),
		method: HTTPClient.Method = HTTPClient.METHOD_GET, body: String = "", as_text: bool = true) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = HTTP_TIMEOUT
	add_child(req)
	var err := req.request(url, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "body": "", "bytes": PackedByteArray(), "error": "request failed (%s)" % error_string(err)}
	var r: Array = await req.request_completed
	req.queue_free()
	var result: int = r[0]
	var code: int = r[1]
	var bytes: PackedByteArray = r[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "body": "", "bytes": PackedByteArray(), "error": _result_text(result)}
	var text := bytes.get_string_from_utf8() if as_text else ""
	if code < 200 or code >= 300:
		return {"ok": false, "code": code, "body": text, "bytes": PackedByteArray(), "error": "HTTP %d" % code}
	return {"ok": true, "code": code, "body": text, "bytes": bytes, "error": ""}


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "server unreachable"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
	return "HTTP request error %d" % result
