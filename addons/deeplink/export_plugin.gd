@tool
extends EditorExportPlugin
## Adds the invite intent-filters to the exported Android activity. Needs the custom (gradle) build
## template: Project → Install Android Build Template, then enable "Use Gradle Build" in the preset.

const CFG := "res://src/resources/net_config.tres"


func _get_name() -> String:
	return "DeepLink"


func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid


func _get_android_manifest_activity_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
	var filters := _filter("<data android:scheme=\"absolutebilliard\" android:host=\"j\" />")
	var url: String = load(CFG).share_base_url
	var m := RegEx.create_from_string("^(https?)://([^:/]+)").search(url)
	if m != null:  # plain http on a bare IP cannot be a verified App Link: it shows the chooser, which is fine
		filters += _filter("<data android:scheme=\"%s\" android:host=\"%s\" android:pathPrefix=\"/j/\" />" % [m.get_string(1), m.get_string(2)])
	return filters


static func _filter(data: String) -> String:
	return """<intent-filter>
	<action android:name="android.intent.action.VIEW" />
	<category android:name="android.intent.category.DEFAULT" />
	<category android:name="android.intent.category.BROWSABLE" />
	%s
</intent-filter>
""" % data
