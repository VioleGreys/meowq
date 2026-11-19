class_name Device
extends RefCounted
## Телефон или ПК. На ПК -- --phone включает поведение телефона (настройки по
## умолчанию, полосы перерисовки, потоки, заготовки) — для замеров «как на
## телефоне» (tests: StressBench, docs/notes/engine.md «Стенд нагрузки»).

static var _mobile := -1


static func mobile() -> bool:
	if _mobile < 0:
		_mobile = 1 if OS.has_feature("mobile") or "--phone" in OS.get_cmdline_user_args() else 0
	return _mobile == 1
