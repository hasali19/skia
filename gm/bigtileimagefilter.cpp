/*
 * Copyright 2015 Google Inc.
 *
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 */

#include "SkImageSource.h"
#include "SkSurface.h"
#include "SkTileImageFilter.h"
#include "gm.h"

static sk_sp<SkImage> create_circle_texture(int size, SkColor color) {
    auto surface(SkSurface::MakeRasterN32Premul(size, size));
    SkCanvas* canvas = surface->getCanvas();
    canvas->clear(0xFF000000);

    SkPaint paint;
    paint.setColor(color);
    paint.setStrokeWidth(3);
    paint.setStyle(SkPaint::kStroke_Style);

    canvas->drawCircle(SkScalarHalf(size), SkScalarHalf(size), SkScalarHalf(size), paint);

    return surface->makeImageSnapshot();
}

namespace skiagm {

class BigTileImageFilterGM : public GM {
public:
    BigTileImageFilterGM() {
        this->setBGColor(0xFF000000);
    }

protected:

    SkString onShortName() override {
        return SkString("bigtileimagefilter");
    }

    SkISize onISize() override{
        return SkISize::Make(kWidth, kHeight);
    }

    void onOnceBeforeDraw() override {
        fRedImage = create_circle_texture(kBitmapSize, SK_ColorRED);
        fGreenImage = create_circle_texture(kBitmapSize, SK_ColorGREEN);
    }

    void onDraw(SkCanvas* canvas) override {
        canvas->clear(SK_ColorBLACK);

        {
            SkPaint p;

            SkRect bound = SkRect::MakeWH(SkIntToScalar(kWidth), SkIntToScalar(kHeight));
            sk_sp<SkImageFilter> imageSource(SkImageSource::Create(fRedImage.get()));
            SkAutoTUnref<SkImageFilter> tif(SkTileImageFilter::Create(
                            SkRect::MakeWH(SkIntToScalar(kBitmapSize), SkIntToScalar(kBitmapSize)),
                            SkRect::MakeWH(SkIntToScalar(kWidth), SkIntToScalar(kHeight)),
                            imageSource.get()));
            p.setImageFilter(tif);

            canvas->saveLayer(&bound, &p);
            canvas->restore();
        }

        {
            SkPaint p2;

            SkRect bound2 = SkRect::MakeWH(SkIntToScalar(kBitmapSize), SkIntToScalar(kBitmapSize));

            SkAutoTUnref<SkImageFilter> tif2(SkTileImageFilter::Create(
                            SkRect::MakeWH(SkIntToScalar(kBitmapSize), SkIntToScalar(kBitmapSize)),
                            SkRect::MakeWH(SkIntToScalar(kBitmapSize), SkIntToScalar(kBitmapSize)),
                            nullptr));
            p2.setImageFilter(tif2);

            canvas->translate(320, 320);
            canvas->saveLayer(&bound2, &p2);
            canvas->setMatrix(SkMatrix::I());

            SkRect bound3 = SkRect::MakeXYWH(320, 320,
                                             SkIntToScalar(kBitmapSize),
                                             SkIntToScalar(kBitmapSize));
            canvas->drawImageRect(fGreenImage.get(), bound2, bound3, nullptr,
                                  SkCanvas::kStrict_SrcRectConstraint);
            canvas->restore();
        }
    }

private:
    static const int kWidth = 512;
    static const int kHeight = 512;
    static const int kBitmapSize = 64;

    sk_sp<SkImage> fRedImage;
    sk_sp<SkImage> fGreenImage;

    typedef GM INHERITED;
};

//////////////////////////////////////////////////////////////////////////////

DEF_GM(return new BigTileImageFilterGM;)
}
