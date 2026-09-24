class_name DlnaXml
extends RefCounted

## Wire formats for a minimal DLNA/UPnP-AV control point: SSDP search
## packets, device descriptions, ContentDirectory Browse SOAP calls and the
## DIDL-Lite listings they return. Pure functions over strings so they can be
## tested without a network; DlnaClient does the I/O.
##
## References: UPnP Device Architecture 1.1 (SSDP §1, description §2,
## SOAP control §3) and ContentDirectory:1 (Browse, DIDL-Lite).

const SSDP_ADDRESS := "239.255.255.250"
const SSDP_PORT := 1900
const MEDIA_SERVER_TYPE := "urn:schemas-upnp-org:device:MediaServer:1"
const CONTENT_DIRECTORY_TYPE := "urn:schemas-upnp-org:service:ContentDirectory:1"
const ROOT_OBJECT_ID := "0"

## Container extensions for URLs/titles that don't carry one. Keys are MIME
## types as they appear in protocolInfo.
const MIME_EXTENSIONS := {
	"video/mp4": "mp4",
	"video/x-m4v": "m4v",
	"video/x-matroska": "mkv",
	"video/matroska": "mkv",
	"video/webm": "webm",
	"video/quicktime": "mov",
	"video/x-msvideo": "avi",
	"video/avi": "avi",
	"video/x-ms-wmv": "wmv",
	"video/x-flv": "flv",
	"video/mp2t": "ts",
	"video/vnd.dlna.mpeg-tts": "ts",
	"video/mpeg": "mpg",
	"video/ogg": "ogv",
}


# --- SSDP ---

## M-SEARCH request for `search_target`. MX is the max seconds a device may
## wait before answering.
static func msearch(search_target: String, mx: int = 2) -> String:
	return "M-SEARCH * HTTP/1.1\r\n" \
		+ "HOST: %s:%d\r\n" % [SSDP_ADDRESS, SSDP_PORT] \
		+ "MAN: \"ssdp:discover\"\r\n" \
		+ "MX: %d\r\n" % mx \
		+ "ST: %s\r\n" % search_target \
		+ "USER-AGENT: Godot/4 UPnP/1.1 VJPlayer/0.1\r\n\r\n"


## Search response (or NOTIFY) → {"location", "usn", "st"} with lowercase
## keys, or {} if it isn't a usable SSDP message.
static func parse_ssdp(packet: String) -> Dictionary:
	var lines := packet.replace("\r\n", "\n").split("\n")
	if lines.is_empty():
		return {}
	var first := lines[0].strip_edges().to_upper()
	if not (first.begins_with("HTTP/1.1 200") or first.begins_with("NOTIFY")):
		return {}
	var headers := {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon <= 0:
			continue
		headers[lines[i].substr(0, colon).strip_edges().to_lower()] = lines[i].substr(colon + 1).strip_edges()
	var location := String(headers.get("location", ""))
	if not location.begins_with("http"):
		return {}
	return {
		"location": location,
		"usn": String(headers.get("usn", "")),
		"st": String(headers.get("st", headers.get("nt", ""))),
	}


# --- device description ---

## Device description XML → {"name", "udn", "service_type", "control_url",
## "icon_url"} for the first ContentDirectory service found (embedded devices
## included), or {} if the device has none. "icon_url" is the largest PNG/JPEG
## in the device's iconList, "" if it has none. `location` is the URL the XML came from; it
## is the base for relative URLs unless the document sets <URLBase>.
static func parse_description(xml: String, location: String) -> Dictionary:
	var p := XMLParser.new()
	if p.open_buffer(xml.to_utf8_buffer()) != OK:
		return {}
	var url_base := ""
	var name := ""
	var udn := ""
	var service_type := ""
	var control_url := ""
	var in_service := false
	var cur_type := ""
	var cur_control := ""
	var in_icon := false
	var icon := {}
	var best_icon := ""
	var best_icon_width := -1
	var field := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				field = local_name(p.get_node_name())
				if field == "service":
					in_service = true
					cur_type = ""
					cur_control = ""
				elif field == "icon":
					in_icon = true
					icon = {}
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				var text := _node_text(p).strip_edges()
				if text == "":
					continue
				if in_icon:
					if field in ["mimetype", "width", "url"]:
						icon[field] = text
					continue
				match field:
					"URLBase":
						url_base = text
					"friendlyName":
						if name == "":
							name = text  # root device's name, not an embedded one's
					"UDN":
						if udn == "":
							udn = text
					"serviceType":
						if in_service:
							cur_type = text
					"controlURL":
						if in_service:
							cur_control = text
			XMLParser.NODE_ELEMENT_END:
				var ended := local_name(p.get_node_name())
				if ended == "service":
					in_service = false
					if control_url == "" and cur_type.begins_with("urn:schemas-upnp-org:service:ContentDirectory:"):
						service_type = cur_type
						control_url = cur_control
				elif ended == "icon":
					in_icon = false
					var mime := String(icon.get("mimetype", "")).to_lower()
					var width := int(icon.get("width", "0"))
					if icon.has("url") and mime in ["image/png", "image/jpeg"] and width > best_icon_width:
						best_icon = icon["url"]
						best_icon_width = width
				field = ""
	if control_url == "":
		return {}
	var base := url_base if url_base != "" else location
	return {
		"name": name if name != "" else host_of(location),
		"udn": udn,
		"service_type": service_type,
		"control_url": resolve_url(base, control_url),
		"icon_url": resolve_url(base, best_icon) if best_icon != "" else "",
	}


# --- Browse ---

## SOAP envelope for ContentDirectory Browse (direct children of `object_id`).
static func browse_body(service_type: String, object_id: String, start: int, count: int) -> String:
	return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" \
		+ "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" \
		+ "<s:Body><u:Browse xmlns:u=\"%s\">" % service_type.xml_escape(true) \
		+ "<ObjectID>%s</ObjectID>" % object_id.xml_escape() \
		+ "<BrowseFlag>BrowseDirectChildren</BrowseFlag>" \
		+ "<Filter>*</Filter>" \
		+ "<StartingIndex>%d</StartingIndex>" % start \
		+ "<RequestedCount>%d</RequestedCount>" % count \
		+ "<SortCriteria></SortCriteria>" \
		+ "</u:Browse></s:Body></s:Envelope>"


## HTTP headers for a Browse POST.
static func browse_headers(service_type: String) -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: text/xml; charset=\"utf-8\"",
		"SOAPAction: \"%s#Browse\"" % service_type,
	])


## Browse response → {"ok": true, "didl", "returned", "total"} or
## {"ok": false, "error"} for a SOAP fault / malformed body.
static func parse_browse_response(xml: String) -> Dictionary:
	var p := XMLParser.new()
	if p.open_buffer(xml.to_utf8_buffer()) != OK:
		return {"ok": false, "error": "unreadable response"}
	var values := {}
	var field := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				field = local_name(p.get_node_name())
				if p.is_empty():
					field = ""
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if field != "":
					values[field] = String(values.get(field, "")) + _node_text(p)
			XMLParser.NODE_ELEMENT_END:
				field = ""
	if values.has("faultstring") or values.has("errorCode"):
		var desc := String(values.get("errorDescription", values.get("faultstring", "SOAP fault")))
		if values.has("errorCode"):
			desc += " (UPnP error %s)" % values["errorCode"]
		return {"ok": false, "error": desc.strip_edges()}
	if not values.has("Result") and not values.has("NumberReturned"):
		return {"ok": false, "error": "no Browse result in response"}
	return {
		"ok": true,
		"didl": String(values.get("Result", "")),
		"returned": int(values.get("NumberReturned", "0")),
		"total": int(values.get("TotalMatches", "0")),
	}


# --- DIDL-Lite ---

## DIDL-Lite XML → Array of entries, in document order:
##   {"kind": "container", "id", "title", "class", "album_art", "date", "child_count"}   (-1 if unknown)
##   {"kind": "item", "id", "title", "class", "album_art", "date", "resources": [{"url", "protocol_info", "mime", "size", "duration", "resolution"}]}
## "album_art" is the first upnp:albumArtURI ("" if none); "date" is dc:date
## as the server wrote it (ISO 8601, so it sorts as text; "" if none).
static func parse_didl(didl: String) -> Array:
	var out: Array = []
	if didl.strip_edges() == "":
		return out
	var p := XMLParser.new()
	if p.open_buffer(didl.to_utf8_buffer()) != OK:
		return out
	var cur: Dictionary = {}
	var res: Dictionary = {}
	var field := ""
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := local_name(p.get_node_name())
				field = ""
				if n == "container" or n == "item":
					cur = {"kind": n, "id": _attr(p, "id"), "title": "", "class": "", "album_art": "", "date": ""}
					if n == "container":
						cur["child_count"] = int(_attr(p, "childCount", "-1"))
					else:
						cur["resources"] = []
					if p.is_empty():
						out.append(cur)
						cur = {}
				elif cur.is_empty():
					continue
				elif n == "res":
					var pi := _attr(p, "protocolInfo")
					res = {
						"url": "",
						"protocol_info": pi,
						"mime": protocol_mime(pi),
						"size": int(_attr(p, "size", "0")),
						"duration": _attr(p, "duration"),
						"resolution": _attr(p, "resolution"),
					}
					field = "res"
					if p.is_empty():
						res = {}  # no URL — useless
						field = ""
				elif n == "title" or n == "class" or n == "date":
					field = n
				elif n == "albumArtURI" and cur["album_art"] == "":
					field = "album_art"
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if cur.is_empty() or field == "":
					continue
				var text := _node_text(p)
				if field == "res":
					res["url"] = String(res["url"]) + text
				else:
					cur[field] = String(cur[field]) + text
			XMLParser.NODE_ELEMENT_END:
				var n := local_name(p.get_node_name())
				if n == "res" and not res.is_empty() and not cur.is_empty() and cur.has("resources"):
					res["url"] = String(res["url"]).strip_edges()
					if res["url"] != "":
						cur["resources"].append(res)
					res = {}
				elif (n == "container" or n == "item") and not cur.is_empty():
					cur["title"] = String(cur["title"]).strip_edges()
					cur["class"] = String(cur["class"]).strip_edges()
					cur["album_art"] = String(cur["album_art"]).strip_edges()
					cur["date"] = String(cur["date"]).strip_edges()
					out.append(cur)
					cur = {}
				field = ""
	return out


## Whether a DIDL item is something the player can show.
static func is_video_item(entry: Dictionary) -> bool:
	if entry.get("kind", "") != "item":
		return false
	if String(entry.get("class", "")).begins_with("object.item.videoItem"):
		return true
	return String(pick_video_resource(entry).get("mime", "")).begins_with("video/")


## Best resource of an item to play: a video/* resource that is the original
## file (DLNA.ORG_CI=0 / absent) over a server-side transcode, falling back to
## the first resource. {} if the item has none.
static func pick_video_resource(entry: Dictionary) -> Dictionary:
	var resources: Array = entry.get("resources", [])
	var fallback: Dictionary = {}
	for r in resources:
		if not String(r.get("mime", "")).begins_with("video/"):
			continue
		if fallback.is_empty():
			fallback = r
		if not String(r.get("protocol_info", "")).contains("DLNA.ORG_CI=1"):
			return r
	if not fallback.is_empty():
		return fallback
	return resources[0] if not resources.is_empty() else {}


## Server-provided thumbnail for an entry: its upnp:albumArtURI, else an
## image resource (MiniDLNA/Serviio/Plex attach a JPEG_TN one to videos),
## preferring a DLNA thumbnail profile. "" if the server offers none.
static func thumbnail_url(entry: Dictionary) -> String:
	var art := String(entry.get("album_art", ""))
	if art != "":
		return art
	var fallback := ""
	for r in entry.get("resources", []):
		if not String(r.get("mime", "")).begins_with("image/"):
			continue
		var pi := String(r.get("protocol_info", ""))
		if pi.contains("_TN") or pi.contains("_SM"):
			return r["url"]
		if fallback == "":
			fallback = r["url"]
	return fallback


## File-like name for a video item: its title with a container extension
## (from the URL, else the MIME type). Projection detection and timecode
## clients key off file names, and DLNA URLs often don't carry one.
static func video_file_name(title: String, resource: Dictionary) -> String:
	var t := title.strip_edges()
	if t == "":
		t = "video"
	if DefaultScreen.is_video(t):
		return t
	var url_file := String(resource.get("url", "")).split("?")[0].get_file().uri_decode()
	var ext := url_file.get_extension().to_lower()
	if not ext in DefaultScreen.VIDEO_EXTENSIONS:
		ext = String(MIME_EXTENSIONS.get(String(resource.get("mime", "")).to_lower(), "mp4"))
	return "%s.%s" % [t.replace("/", "-").replace("\\", "-"), ext]


# --- helpers ---

## "http-get:*:video/mp4:DLNA.ORG_PN=..." → "video/mp4".
static func protocol_mime(protocol_info: String) -> String:
	var parts := protocol_info.split(":")
	return parts[2].strip_edges().to_lower() if parts.size() >= 3 else ""


## "dc:title" → "title".
static func local_name(qualified: String) -> String:
	var colon := qualified.find(":")
	return qualified.substr(colon + 1) if colon >= 0 else qualified


## Resolve a (possibly relative) URL from a description against `base`.
static func resolve_url(base: String, url: String) -> String:
	if url.begins_with("http://") or url.begins_with("https://"):
		return url
	var scheme_end := base.find("://")
	if scheme_end < 0:
		return url
	var path_start := base.find("/", scheme_end + 3)
	var origin := base if path_start < 0 else base.substr(0, path_start)
	if url.begins_with("/"):
		return origin + url
	var base_path := "/" if path_start < 0 else base.substr(path_start).split("?")[0]
	var dir := base_path.substr(0, base_path.rfind("/") + 1)
	return origin + dir + url


## "http://192.168.1.5:8200/rootDesc.xml" → "192.168.1.5".
static func host_of(url: String) -> String:
	var rest := url.split("://")[-1]
	return rest.split("/")[0].split(":")[0]


static func _node_text(p: XMLParser) -> String:
	# XMLParser keeps CDATA contents in the node name.
	return p.get_node_name() if p.get_node_type() == XMLParser.NODE_CDATA else p.get_node_data()


static func _attr(p: XMLParser, name: String, default: String = "") -> String:
	return p.get_named_attribute_value_safe(name) if p.has_attribute(name) else default
