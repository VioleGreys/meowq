extends SceneTree
## Графика карты для APK: .ctex формата ETC2 (импорт Godot) → data/art/*.etc2.zst
## (сжатие zstd; MapView._art_src / _ctex_bytes). Godot кладёт .ctex в APK без
## сжатия (4 × 40 МБ), упакованные — ~60 МБ; assets/map в APK не входит
## (exclude_filter в export_presets.cfg). Зовёт tools/build_apk.sh после импорта:
##   godot --headless --path . --script res://tools/pack_art.gd

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MapView.ART_PACK_DIR))
	var total := 0
	for k in MapView.ART_FILES:
		var src: String = MapView.ART_DIR + MapView.ART_FILES[k]
		var cf := ConfigFile.new()
		if cf.load(src + ".import") != OK or not cf.has_section_key("remap", "path.etc2"):
			push_error("pack_art: нет импорта ETC2 у %s (textures/vram_compression/import_etc2_astc)" % src)
			quit(1)
			return
		var ctex := FileAccess.get_file_as_bytes(str(cf.get_value("remap", "path.etc2")))
		if ctex.size() < 52 or ctex.slice(0, 4).get_string_from_ascii() != "GST2":
			push_error("pack_art: не .ctex — " + src)
			quit(1)
			return
		var out := PackedByteArray()
		out.resize(16)
		out.encode_u32(4, ctex.size())
		out.encode_u32(8, ctex.decode_u32(8))     # ширина исходной картинки
		out.encode_u32(12, ctex.decode_u32(12))   # высота
		for i in 4:
			out[i] = MapView.ART_PACK_MAGIC.unicode_at(i)
		out.append_array(ctex.compress(FileAccess.COMPRESSION_ZSTD))
		var dst := MapView.ART_PACK_DIR + src.get_file() + ".etc2.zst"
		var f := FileAccess.open(dst, FileAccess.WRITE)
		f.store_buffer(out)
		f.close()
		total += out.size()
		print("pack_art: %s — %.1f → %.1f МБ" % [dst, ctex.size() / 1048576.0, out.size() / 1048576.0])
	print("pack_art: всего %.1f МБ" % (total / 1048576.0))
	quit()
