<?php

namespace App\Http\Controllers;

use App\Models\Media;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;

class MediaController extends Controller
{
    public function form()
    {
        return view('dashboard.upload');
    }

    // PNG/JPEG/GIF in, four derivatives out: GD jpeg + webp, Imagick jpeg +
    // webp, all stored through Storage. Dimensions are asserted by the suite,
    // never the encoded bytes (those depend on the codec build).
    public function store(Request $request)
    {
        $request->validate(['image' => 'required|file|image|mimes:png,jpg,jpeg,gif|max:4096']);
        $file = $request->file('image');
        $bytes = file_get_contents($file->getRealPath());
        $dir = 'uploads/'.Str::lower(Str::random(12));
        $disk = Storage::disk('local');

        $disk->put("$dir/original.".$file->guessExtension(), $bytes);
        $result = ['original' => ['mime' => $file->getMimeType(), 'size' => strlen($bytes)] + $this->dims($bytes)];

        $src = imagecreatefromstring($bytes);
        $w = imagesx($src);
        $h = imagesy($src);
        $tw = 32;
        $th = max(1, (int) round($h * $tw / $w));
        $dst = imagecreatetruecolor($tw, $th);
        imagecopyresampled($dst, $src, 0, 0, 0, 0, $tw, $th, $w, $h);
        ob_start();
        imagejpeg($dst, null, 85);
        $gdJpeg = ob_get_clean();
        $disk->put("$dir/gd.jpg", $gdJpeg);
        $result['gd_jpeg'] = $this->dims($gdJpeg) + ['size' => strlen($gdJpeg)];
        if (function_exists('imagewebp')) {
            ob_start();
            imagewebp($dst, null, 80);
            $gdWebp = ob_get_clean();
            $disk->put("$dir/gd.webp", $gdWebp);
            $result['gd_webp'] = $this->dims($gdWebp) + ['size' => strlen($gdWebp)];
        }
        $rot = imagerotate($src, 90, 0);
        $result['gd_rotated'] = ['width' => imagesx($rot), 'height' => imagesy($rot)];

        $im = new \Imagick();
        $im->readImageBlob($bytes);
        $im->thumbnailImage(24, 0);
        $im->setImageFormat('jpeg');
        $im->setImageCompressionQuality(80);
        $imJpeg = $im->getImageBlob();
        $disk->put("$dir/im.jpg", $imJpeg);
        $result['imagick_jpeg'] = $this->dims($imJpeg) + ['size' => strlen($imJpeg)];
        $im->setImageFormat('webp');
        $imWebp = $im->getImageBlob();
        $disk->put("$dir/im.webp", $imWebp);
        $result['imagick_webp'] = $this->dims($imWebp) + ['size' => strlen($imWebp)];
        $im->rotateImage(new \ImagickPixel('none'), 90);
        $result['imagick_rotated'] = ['width' => $im->getImageWidth(), 'height' => $im->getImageHeight()];
        // The GD output read back through ImageMagick: two libraries, one file.
        $back = new \Imagick();
        $back->readImageBlob($gdJpeg);
        $result['imagick_reads_gd'] = ['width' => $back->getImageWidth(), 'height' => $back->getImageHeight(), 'format' => $back->getImageFormat()];

        $media = Media::create([
            'user_id' => Auth::id(),
            'disk' => 'local',
            'path' => $dir,
            'original_name' => $file->getClientOriginalName(),
            'mime' => $result['original']['mime'],
            'size' => strlen($bytes),
            'meta' => $result,
        ]);
        $result['id'] = $media->id;
        $result['files'] = collect($disk->files($dir))->map(function ($f) {
            return basename($f);
        })->values()->all();

        return response()->json($result);
    }

    public function show($id, $file)
    {
        $media = Media::findOrFail($id);
        abort_unless(in_array($file, ['gd.jpg', 'gd.webp', 'im.jpg', 'im.webp'], true), 404);

        return Storage::disk($media->disk)->response($media->path.'/'.$file);
    }

    private function dims($bytes)
    {
        $info = getimagesizefromstring($bytes);
        if ($info === false) {
            // getimagesize() reads WebP from 7.1; before, ImageMagick does it.
            $im = new \Imagick();
            $im->readImageBlob($bytes);

            return ['width' => $im->getImageWidth(), 'height' => $im->getImageHeight(), 'mime' => str_replace('image/x-webp', 'image/webp', $im->getImageMimeType())];
        }

        return ['width' => $info[0], 'height' => $info[1], 'mime' => $info['mime']];
    }
}
