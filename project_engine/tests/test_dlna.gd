extends RefCounted

## DLNA control-point wire formats (DlnaXml) and network-URL playback
## plumbing. Fixtures follow what MiniDLNA / Serviio / Windows Media Player
## sharing actually send.

const DESCRIPTION := """<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<device>
<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
<friendlyName>NAS: minidlna</friendlyName>
<UDN>uuid:4d696e69-444c-164e-9d41-b827eb1a2b3c</UDN>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/ctl/ConnectionMgr</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId><controlURL>/ctl/ContentDir</controlURL></service>
</serviceList>
</device>
</root>"""

const DIDL := """<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
<container id="64$0" parentID="64" restricted="1" childCount="3"><dc:title>Concerts &amp; Sets</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>
<item id="64$1" parentID="64" restricted="1"><dc:title>Stage_180_LR</dc:title><dc:date>2024-05-01T20:15:00</dc:date><upnp:class>object.item.videoItem</upnp:class>
<res protocolInfo="http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_CI=1" size="1000">http://192.168.1.5:8200/transcode/1.mp4</res>
<res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0" size="233299608" duration="0:03:08.885" resolution="1920x1080">http://192.168.1.5:8200/MediaItems/22.mp4</res>
<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">http://192.168.1.5:8200/Thumbnails/22.jpg</res>
</item>
<item id="64$2" parentID="64" restricted="1"><dc:title>Track.01</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>
<res protocolInfo="http-get:*:audio/mpeg:*">http://192.168.1.5:8200/MediaItems/23.mp3</res></item>
<item id="64$3" parentID="64" restricted="1"><dc:title>no class</dc:title>
<res protocolInfo="http-get:*:video/x-matroska:*">http://192.168.1.5:8200/get/64$3?x=1&amp;y=2</res></item>
</DIDL-Lite>"""


static func _browse_response(didl: String, returned: int, total: int) -> String:
	return """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>
<u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result>%s</Result>
<NumberReturned>%d</NumberReturned><TotalMatches>%d</TotalMatches><UpdateID>7</UpdateID></u:BrowseResponse>
</s:Body></s:Envelope>""" % [didl.xml_escape(), returned, total]


static func test_msearch_packet(t: TestCase) -> void:
	var m := DlnaXml.msearch(DlnaXml.MEDIA_SERVER_TYPE)
	t.assert_true(m.begins_with("M-SEARCH * HTTP/1.1\r\n"))
	t.assert_has(m, "HOST: 239.255.255.250:1900\r\n")
	t.assert_has(m, "MAN: \"ssdp:discover\"\r\n")
	t.assert_has(m, "ST: urn:schemas-upnp-org:device:MediaServer:1\r\n")
	t.assert_true(m.ends_with("\r\n\r\n"), "blank line terminates the request")


static func test_parse_ssdp(t: TestCase) -> void:
	var msg := DlnaXml.parse_ssdp("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1810\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n"
		+ "USN: uuid:abc::urn:schemas-upnp-org:device:MediaServer:1\r\nLocation: http://192.168.1.5:8200/rootDesc.xml\r\n\r\n")
	t.assert_eq(msg.get("location"), "http://192.168.1.5:8200/rootDesc.xml", "header names are case-insensitive")
	t.assert_eq(msg.get("st"), DlnaXml.MEDIA_SERVER_TYPE)
	t.assert_eq(DlnaXml.parse_ssdp("M-SEARCH * HTTP/1.1\r\nHOST: x\r\n\r\n"), {}, "other clients' searches are ignored")
	t.assert_eq(DlnaXml.parse_ssdp("HTTP/1.1 200 OK\r\nST: x\r\n\r\n"), {}, "no LOCATION")


static func test_parse_description(t: TestCase) -> void:
	var s := DlnaXml.parse_description(DESCRIPTION, "http://192.168.1.5:8200/rootDesc.xml")
	t.assert_eq(s.get("name"), "NAS: minidlna")
	t.assert_eq(s.get("udn"), "uuid:4d696e69-444c-164e-9d41-b827eb1a2b3c")
	t.assert_eq(s.get("service_type"), DlnaXml.CONTENT_DIRECTORY_TYPE)
	t.assert_eq(s.get("control_url"), "http://192.168.1.5:8200/ctl/ContentDir", "picks ContentDirectory, not ConnectionManager")
	# <URLBase> overrides the location as the base for relative URLs.
	var with_base := DESCRIPTION.replace("<device>", "<URLBase>http://10.0.0.9:9000/upnp/</URLBase><device>") \
		.replace("/ctl/ContentDir", "cds/control")
	t.assert_eq(DlnaXml.parse_description(with_base, "http://192.168.1.5:8200/rootDesc.xml").get("control_url"),
		"http://10.0.0.9:9000/upnp/cds/control")
	# No ContentDirectory → not browsable.
	t.assert_eq(DlnaXml.parse_description(DESCRIPTION.replace("ContentDirectory:1", "AVTransport:1"), "http://h/d.xml"), {})


static func test_resolve_url(t: TestCase) -> void:
	t.assert_eq(DlnaXml.resolve_url("http://h:1/a/desc.xml", "/ctl"), "http://h:1/ctl")
	t.assert_eq(DlnaXml.resolve_url("http://h:1/a/desc.xml", "ctl"), "http://h:1/a/ctl")
	t.assert_eq(DlnaXml.resolve_url("http://h:1", "ctl"), "http://h:1/ctl")
	t.assert_eq(DlnaXml.resolve_url("http://h:1/a/", "http://x/y"), "http://x/y")
	t.assert_eq(DlnaXml.host_of("http://192.168.1.5:8200/rootDesc.xml"), "192.168.1.5")


static func test_browse_request(t: TestCase) -> void:
	var body := DlnaXml.browse_body(DlnaXml.CONTENT_DIRECTORY_TYPE, "64$<&>", 200, 50)
	t.assert_has(body, "<u:Browse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\">")
	t.assert_has(body, "<ObjectID>64$&lt;&amp;&gt;</ObjectID>", "object ids are XML-escaped")
	t.assert_has(body, "<BrowseFlag>BrowseDirectChildren</BrowseFlag>")
	t.assert_has(body, "<StartingIndex>200</StartingIndex><RequestedCount>50</RequestedCount>")
	var headers := DlnaXml.browse_headers(DlnaXml.CONTENT_DIRECTORY_TYPE)
	t.assert_true(headers.has("SOAPAction: \"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\""))


static func test_parse_browse_response(t: TestCase) -> void:
	var r := DlnaXml.parse_browse_response(_browse_response(DIDL, 4, 9))
	t.assert_ok(r)
	t.assert_eq(r.get("returned"), 4)
	t.assert_eq(r.get("total"), 9)
	t.assert_true(String(r.get("didl")).begins_with("<DIDL-Lite"), "Result is unescaped once, back to DIDL XML")
	# Some servers wrap the DIDL in CDATA instead of escaping it.
	var cdata := _browse_response("", 0, 0).replace("<Result></Result>", "<Result><![CDATA[%s]]></Result>" % DIDL)
	t.assert_eq(DlnaXml.parse_didl(DlnaXml.parse_browse_response(cdata).get("didl", "")).size(), 4)
	var fault := DlnaXml.parse_browse_response("""<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>
<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
<errorCode>701</errorCode><errorDescription>No such object</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>""")
	t.assert_false(fault.get("ok", true))
	t.assert_eq(fault.get("error"), "No such object (UPnP error 701)")
	t.assert_false(DlnaXml.parse_browse_response("<html>nope</html>").get("ok", true))


static func test_parse_didl(t: TestCase) -> void:
	var entries := DlnaXml.parse_didl(DIDL)
	t.assert_eq(entries.size(), 4)
	t.assert_eq(entries[0].get("kind"), "container")
	t.assert_eq(entries[0].get("id"), "64$0")
	t.assert_eq(entries[0].get("title"), "Concerts & Sets")
	t.assert_eq(entries[0].get("child_count"), 3)
	var video: Dictionary = entries[1]
	t.assert_eq(video.get("class"), "object.item.videoItem")
	t.assert_eq(video.get("date"), "2024-05-01T20:15:00")
	t.assert_eq(entries[0].get("date"), "", "no dc:date")
	t.assert_eq(video.get("resources", []).size(), 3)
	t.assert_eq(video["resources"][1].get("mime"), "video/mp4")
	t.assert_eq(video["resources"][1].get("size"), 233299608)
	t.assert_eq(video["resources"][1].get("duration"), "0:03:08.885")
	t.assert_eq(entries[3]["resources"][0].get("url"), "http://192.168.1.5:8200/get/64$3?x=1&y=2", "entities in URLs decoded")


static func test_thumbnails(t: TestCase) -> void:
	var entries := DlnaXml.parse_didl(DIDL)
	t.assert_eq(DlnaXml.thumbnail_url(entries[1]), "http://192.168.1.5:8200/Thumbnails/22.jpg", "JPEG_TN resource")
	t.assert_eq(DlnaXml.thumbnail_url(entries[0]), "", "folder without art")
	t.assert_eq(DlnaXml.thumbnail_url(entries[3]), "", "no image resource")
	var didl := """<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">
<container id="1" childCount="2"><dc:title>Shows</dc:title><upnp:albumArtURI dlna:profileID="JPEG_TN">http://h:32469/art/1.jpg</upnp:albumArtURI><upnp:albumArtURI>http://h:32469/art/1-big.jpg</upnp:albumArtURI></container>
<item id="2"><dc:title>Clip</dc:title><upnp:class>object.item.videoItem</upnp:class><upnp:albumArtURI> http://h:32469/art/2.jpg </upnp:albumArtURI>
<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_TN">http://h:32469/res/2.jpg</res>
<res protocolInfo="http-get:*:video/mp4:*">http://h:32469/2.mp4</res></item>
</DIDL-Lite>"""
	var art := DlnaXml.parse_didl(didl)
	t.assert_eq(DlnaXml.thumbnail_url(art[0]), "http://h:32469/art/1.jpg", "first albumArtURI wins")
	t.assert_eq(DlnaXml.thumbnail_url(art[1]), "http://h:32469/art/2.jpg", "albumArtURI over image resource, trimmed")
	t.assert_eq(art[1].get("title"), "Clip")
	t.assert_true(DlnaXml.is_video_item(art[1]))
	t.assert_eq(DlnaXml.pick_video_resource(art[1]).get("url"), "http://h:32469/2.mp4")


static func test_description_icon(t: TestCase) -> void:
	t.assert_eq(DlnaXml.parse_description(DESCRIPTION, "http://h:8200/d.xml").get("icon_url"), "", "no iconList")
	var with_icons := DESCRIPTION.replace("<serviceList>", """<iconList>
<icon><mimetype>image/png</mimetype><width>48</width><height>48</height><depth>24</depth><url>/icons/sm.png</url></icon>
<icon><mimetype>image/png</mimetype><width>120</width><height>120</height><depth>24</depth><url>/icons/lrg.png</url></icon>
<icon><mimetype>image/x-bmp</mimetype><width>256</width><height>256</height><depth>24</depth><url>/icons/huge.bmp</url></icon>
</iconList><serviceList>""")
	var s := DlnaXml.parse_description(with_icons, "http://h:8200/d.xml")
	t.assert_eq(s.get("icon_url"), "http://h:8200/icons/lrg.png", "largest PNG/JPEG")
	t.assert_eq(s.get("name"), "NAS: minidlna", "icon fields don't leak into device fields")
	t.assert_eq(s.get("control_url"), "http://h:8200/ctl/ContentDir")


static func test_placeholder_and_image_decode(t: TestCase) -> void:
	for kind in ["up", "folder", "server", "video", "script"]:
		var tex := BrowserView.placeholder(kind)
		t.assert_true(tex != null and tex.get_width() == BrowserView.TILE_ICON.x, kind)
	var img := Image.create_empty(8, 4, false, Image.FORMAT_RGB8)
	img.fill(Color.RED)
	var png := BrowserView.texture_from_bytes(img.save_png_to_buffer())
	t.assert_true(png != null and png.get_height() == 4, "PNG decodes")
	var jpg := BrowserView.texture_from_bytes(img.save_jpg_to_buffer())
	t.assert_true(jpg != null and jpg.get_width() == 8, "JPEG decodes")
	t.assert_eq(BrowserView.texture_from_bytes("<html>404</html>".to_utf8_buffer()), null, "non-image → null")


static func test_video_selection(t: TestCase) -> void:
	var entries := DlnaXml.parse_didl(DIDL)
	t.assert_true(DlnaXml.is_video_item(entries[1]))
	t.assert_false(DlnaXml.is_video_item(entries[2]), "music track hidden")
	t.assert_true(DlnaXml.is_video_item(entries[3]), "no upnp:class, but a video/* resource")
	t.assert_false(DlnaXml.is_video_item(entries[0]), "containers aren't items")
	# The original file wins over the server's transcode and the thumbnail.
	var res := DlnaXml.pick_video_resource(entries[1])
	t.assert_eq(res.get("url"), "http://192.168.1.5:8200/MediaItems/22.mp4")


static func test_video_file_name(t: TestCase) -> void:
	var entries := DlnaXml.parse_didl(DIDL)
	var name := DlnaXml.video_file_name("Stage_180_LR", DlnaXml.pick_video_resource(entries[1]))
	t.assert_eq(name, "Stage_180_LR.mp4", "extension from the URL")
	t.assert_eq(VideoProjection.detect(name), "180_sbs", "title tokens drive projection detection")
	t.assert_eq(DlnaXml.video_file_name("no class", DlnaXml.pick_video_resource(entries[3])), "no class.mkv", "extension from MIME")
	t.assert_eq(DlnaXml.video_file_name("Movie.2024", {"url": "http://h/x", "mime": "video/x-unknown"}), "Movie.2024.mp4",
		"dots in titles are kept, not taken as an extension")
	t.assert_eq(DlnaXml.video_file_name("already.mkv", {}), "already.mkv")


static func test_url_playback_timeline(t: TestCase) -> void:
	t.assert_true(DefaultScreen.is_url("http://192.168.1.5:8200/MediaItems/22.mp4"))
	t.assert_false(DefaultScreen.is_url("C:/v/movie.mp4"))
	t.assert_eq(DefaultScreen.sidecar_script("http://h/v.mp4"), "", "no sidecar lookup over the network")
	var data := DefaultScreen.timeline_for_video("http://192.168.1.5:8200/MediaItems/22.mp4", "Stage_180_LR.mp4")
	t.assert_eq(data.title(), "Stage_180_LR.mp4")
	t.assert_eq(data.meta.get("video_name"), "Stage_180_LR.mp4")
	t.assert_eq(data.resolve(String(data.media.video)), "http://192.168.1.5:8200/MediaItems/22.mp4", "URLs resolve to themselves")
	# Scripts can reference network videos too.
	var scripted := TimelineData.new()
	scripted.base_dir = "C:/scripts/show"
	t.assert_eq(scripted.resolve("https://cdn.example/v.mp4"), "https://cdn.example/v.mp4")
