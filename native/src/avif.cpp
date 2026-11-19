// Декодер AVIF для тайлов заготовок карты (пакеты APK; docs/notes/ui.md).
// libavif + dav1d (только декодер) собираются отдельно: docs/notes/build.md.
#include "meowq_core.h"

using namespace godot;

#ifndef MEOWQ_AVIF
PackedByteArray MeowqCore::avif_rgba(const PackedByteArray &data) const {
	return PackedByteArray();   // собрано без libavif (tools/build_avif.sh)
}
#else
#include <avif/avif.h>

PackedByteArray MeowqCore::avif_rgba(const PackedByteArray &data) const {
	PackedByteArray out;
	avifDecoder *dec = avifDecoderCreate();
	if (dec == nullptr) {
		return out;
	}
	dec->maxThreads = 1;   // зовут из пула потоков — по тайлу на поток
	dec->ignoreExif = AVIF_TRUE;
	dec->ignoreXMP = AVIF_TRUE;
	if (avifDecoderSetIOMemory(dec, data.ptr(), (size_t)data.size()) == AVIF_RESULT_OK &&
			avifDecoderParse(dec) == AVIF_RESULT_OK && avifDecoderNextImage(dec) == AVIF_RESULT_OK) {
		avifRGBImage rgb;
		avifRGBImageSetDefaults(&rgb, dec->image);
		rgb.format = AVIF_RGB_FORMAT_RGBA;
		rgb.depth = 8;
		out.resize((int64_t)rgb.width * rgb.height * 4);
		rgb.pixels = out.ptrw();
		rgb.rowBytes = rgb.width * 4;
		if (avifImageYUVToRGB(dec->image, &rgb) != AVIF_RESULT_OK) {
			out.clear();
		}
	}
	avifDecoderDestroy(dec);
	return out;
}
#endif
