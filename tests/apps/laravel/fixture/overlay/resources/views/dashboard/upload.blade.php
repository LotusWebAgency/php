@extends('layout')
@section('title', 'Upload')
@section('content')
    <h1>Upload an image</h1>
    <form action="/dashboard/upload" method="post" enctype="multipart/form-data" id="upload-form">
        {{ csrf_field() }}
        <input type="file" name="image">
        <button>Upload</button>
    </form>
@endsection
