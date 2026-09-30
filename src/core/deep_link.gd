class_name DeepLink
extends RefCounted
## Invite links (docs/plan/04 §2.3): `absolutebilliard://j/CODE` and `<share_base_url>/j/CODE`.
## Launch URL readback: desktop = command-line arg; Android = AndroidRuntime → Activity.getIntent()
## (GodotActivity.onNewIntent replaces the activity intent, so a warm start reads the same way).

const SCHEME := "absolutebilliard"
static var _last_consumed := ""


## Lobby code inside any invite URL, or "".
static func code_from_url(url: String) -> String:
	var rx := RegEx.create_from_string("^(?:%s://|https?://[^/]+/)j/([0-9A-Za-z]{6})/?$" % SCHEME)
	var m := rx.search(url.strip_edges())
	return LobbyCode.normalize(m.get_string(1)) if m != null else ""


static func launch_url() -> String:
	if Engine.has_singleton("AndroidRuntime"):
		var intent: Object = Engine.get_singleton("AndroidRuntime").getActivity().getIntent()
		var data: Variant = intent.getDataString() if intent != null else null
		return data if data is String else ""
	for a in OS.get_cmdline_args():
		if code_from_url(a) != "":
			return a
	return ""


## The code the app was launched with, once per distinct link (call again on resume for warm starts).
static func take_launch_code() -> String:
	var url := launch_url()
	if url == "" or url == _last_consumed:
		return ""
	_last_consumed = url
	return code_from_url(url)


## Native share sheet on Android; clipboard elsewhere. Returns true when a sheet was shown.
static func share(text: String) -> bool:
	if not Engine.has_singleton("AndroidRuntime"):
		DisplayServer.clipboard_set(text)
		return false
	var rt := Engine.get_singleton("AndroidRuntime")
	var Intent := JavaClassWrapper.wrap("android.content.Intent")
	var send: Object = Intent.Intent()
	send.setAction(Intent.ACTION_SEND)
	send.putExtra(Intent.EXTRA_TEXT, text)
	send.setType("text/plain")
	rt.getActivity().startActivity(Intent.createChooser(send, "Invite friends"))
	return true
