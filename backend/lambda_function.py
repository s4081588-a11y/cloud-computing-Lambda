# Source adaptation: based on existing root-level app.py and lambda_backend/lambda_function.py in this repository.
import json
import os
import re
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError, EndpointConnectionError, NoCredentialsError

AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
DYNAMODB_ENDPOINT_URL = os.getenv("DYNAMODB_ENDPOINT_URL", "").strip()
USERS_TABLE_NAME = os.getenv("USERS_TABLE_NAME", "login")
MUSIC_TABLE_NAME = os.getenv("MUSIC_TABLE_NAME", "music")
SUBSCRIPTIONS_TABLE_NAME = os.getenv("SUBSCRIPTIONS_TABLE_NAME", "subscriptions")
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "")
PRESIGNED_URL_TTL = int(os.getenv("PRESIGNED_URL_TTL", "3600"))
_ALLOWED_ORIGINS = [o.strip() for o in os.getenv("CORS_ALLOW_ORIGINS", "*").split(",") if o.strip()]


def _boto3_kwargs():
    kwargs = {"region_name": AWS_REGION}
    if DYNAMODB_ENDPOINT_URL:
        kwargs["endpoint_url"] = DYNAMODB_ENDPOINT_URL
    return kwargs


dynamodb = boto3.resource("dynamodb", **_boto3_kwargs())
s3_client = boto3.client("s3", region_name=AWS_REGION)

users_table = dynamodb.Table(USERS_TABLE_NAME)
music_table = dynamodb.Table(MUSIC_TABLE_NAME)
subs_table = dynamodb.Table(SUBSCRIPTIONS_TABLE_NAME)


def _clean(value):
    return str(value or "").strip()


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _song_id(title, artist, year):
    return f"{title}#{artist}#{year}"


def _method(event):
    return (event.get("httpMethod") or event.get("requestContext", {}).get("http", {}).get("method") or "GET").upper()


def _path(event):
    return (event.get("rawPath") or event.get("path") or "/").rstrip("/") or "/"


def _query_params(event):
    return event.get("queryStringParameters") or {}


def _origin(event):
    headers = event.get("headers") or {}
    return headers.get("origin") or headers.get("Origin") or ""


def _cors_origin(request_origin):
    if not _ALLOWED_ORIGINS:
        return "*"
    if "*" in _ALLOWED_ORIGINS:
        return "*"
    if request_origin and request_origin in _ALLOWED_ORIGINS:
        return request_origin
    if len(_ALLOWED_ORIGINS) == 1:
        return _ALLOWED_ORIGINS[0]
    return _ALLOWED_ORIGINS[0]


def _response(event, status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": _cors_origin(_origin(event)),
            "Access-Control-Allow-Headers": "Content-Type,Authorization",
            "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
            "Referrer-Policy": "strict-origin-when-cross-origin",
        },
        "body": json.dumps(payload),
    }


def _json_body(event):
    body = event.get("body")
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return {}


def _collect_query_items(table, **query_kwargs):
    items = []
    response = table.query(**query_kwargs)
    items.extend(response.get("Items", []))

    while "LastEvaluatedKey" in response:
        query_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
        response = table.query(**query_kwargs)
        items.extend(response.get("Items", []))

    return items


def _collect_scan_items(table, **scan_kwargs):
    items = []
    response = table.scan(**scan_kwargs)
    items.extend(response.get("Items", []))

    while "LastEvaluatedKey" in response:
        scan_kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
        response = table.scan(**scan_kwargs)
        items.extend(response.get("Items", []))

    return items


def _build_regex_pattern(value):
    text = _clean(value)
    if not text:
        return None

    if text.lower().startswith("re:"):
        raw_pattern = text[3:].strip()
        if not raw_pattern:
            return None
        try:
            return re.compile(raw_pattern, re.IGNORECASE)
        except re.error:
            pass

    tokens = [re.escape(token) for token in re.split(r"\s+", text) if token]
    if not tokens:
        return None

    pattern = "".join(f"(?=.*{token})" for token in tokens) + ".*"
    return re.compile(pattern, re.IGNORECASE)


def _regex_match(pattern, value):
    if pattern is None:
        return True
    return bool(pattern.search(_clean(value)))


def _sign_image(song):
    image_key = song.get("image_key")

    if S3_BUCKET_NAME and image_key:
        try:
            return s3_client.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET_NAME, "Key": image_key},
                ExpiresIn=PRESIGNED_URL_TTL,
            )
        except ClientError:
            pass

    return song.get("img_url") or song.get("image_url") or ""


def _serialize_song(song):
    return {
        "song_id": song.get("song_id") or _song_id(song.get("title", ""), song.get("artist", ""), song.get("year", "")),
        "title": song.get("title", ""),
        "artist": song.get("artist", ""),
        "year": song.get("year", ""),
        "album": song.get("album", ""),
        "image_url": _sign_image(song),
        "image_key": song.get("image_key", ""),
    }


def _fetch_music_candidates(title, artist, album, year):
    if album:
        return _collect_scan_items(music_table)

    if title:
        exact_title = _collect_query_items(music_table, KeyConditionExpression=Key("title").eq(title))
        if exact_title:
            return exact_title

    if artist and year:
        try:
            exact_artist_year = _collect_query_items(
                music_table,
                IndexName="ArtistYearIndex",
                KeyConditionExpression=Key("artist").eq(artist) & Key("year").eq(year),
            )
            if exact_artist_year:
                return exact_artist_year
        except ClientError:
            pass

    if artist:
        try:
            exact_artist = _collect_query_items(
                music_table,
                IndexName="ArtistYearIndex",
                KeyConditionExpression=Key("artist").eq(artist),
            )
            if exact_artist:
                return exact_artist
        except ClientError:
            pass

    if year:
        try:
            exact_year = _collect_query_items(
                music_table,
                IndexName="YearTitleIndex",
                KeyConditionExpression=Key("year").eq(year),
            )
            if exact_year:
                return exact_year
        except ClientError:
            pass

    return _collect_scan_items(music_table)


def _apply_song_filters(items, title, artist, album, year):
    title_pattern = _build_regex_pattern(title)
    artist_pattern = _build_regex_pattern(artist)
    album_pattern = _build_regex_pattern(album)
    year_pattern = _build_regex_pattern(year)

    filtered = []
    for song in items:
        if not _regex_match(title_pattern, song.get("title")):
            continue
        if not _regex_match(artist_pattern, song.get("artist")):
            continue
        if not _regex_match(album_pattern, song.get("album")):
            continue
        if not _regex_match(year_pattern, song.get("year")):
            continue
        filtered.append(song)

    return filtered


def _route_register(event):
    data = _json_body(event)

    email = _clean(data.get("email"))
    username = _clean(data.get("username") or data.get("user_name"))
    password = _clean(data.get("password"))

    if not email or not username or not password:
        return _response(event, 400, {"message": "email, username and password are required"})

    existing = users_table.get_item(Key={"email": email}).get("Item")
    if existing:
        return _response(event, 409, {"message": "The email already exists"})

    users_table.put_item(
        Item={
            "email": email,
            "username": username,
            "user_name": username,
            "password": password,
            "created_at": _now_iso(),
        }
    )

    return _response(event, 201, {"message": "User registered"})


def _route_login(event):
    data = _json_body(event)

    email = _clean(data.get("email"))
    password = _clean(data.get("password"))

    if not email or not password:
        return _response(event, 400, {"message": "email and password are required"})

    user = users_table.get_item(Key={"email": email}).get("Item")

    if not user or user.get("password") != password:
        return _response(event, 401, {"message": "email or password is invalid"})

    return _response(
        event,
        200,
        {
            "message": "Login success",
            "user": {
                "email": user.get("email"),
                "username": user.get("username") or user.get("user_name"),
            },
        },
    )


def _route_music(event):
    qs = _query_params(event)
    title = _clean(qs.get("title"))
    artist = _clean(qs.get("artist"))
    album = _clean(qs.get("album"))
    year = _clean(qs.get("year"))

    if not any([title, artist, album, year]):
        return _response(event, 400, {"message": "At least one query field is required", "items": []})

    candidates = _fetch_music_candidates(title, artist, album, year)
    filtered = _apply_song_filters(candidates, title, artist, album, year)

    unique = {}
    for song in filtered:
        sid = song.get("song_id") or _song_id(song.get("title", ""), song.get("artist", ""), song.get("year", ""))
        unique[sid] = _serialize_song(song)

    result = sorted(unique.values(), key=lambda x: (x["title"].lower(), x["artist"].lower(), x["year"]))
    return _response(event, 200, result)


def _load_song_by_identity(title, artist, year):
    response = music_table.get_item(Key={"title": title, "artist_year": f"{artist}#{year}"})
    return response.get("Item")


def _route_subscriptions_get(event):
    qs = _query_params(event)
    user_email = _clean(qs.get("user") or qs.get("email"))
    if not user_email:
        return _response(event, 400, {"message": "email is required", "items": []})

    items = _collect_query_items(subs_table, KeyConditionExpression=Key("user_email").eq(user_email))
    songs = [_serialize_song(item) for item in items]
    songs.sort(key=lambda x: (x["title"].lower(), x["artist"].lower(), x["year"]))
    return _response(event, 200, songs)


def _route_subscriptions_post(event):
    data = _json_body(event)
    user_email = _clean(data.get("user") or data.get("user_email") or data.get("email"))

    if not user_email:
        return _response(event, 400, {"message": "user_email is required"})

    title = _clean(data.get("title"))
    artist = _clean(data.get("artist"))
    year = _clean(data.get("year"))

    if not title or not artist or not year:
        return _response(event, 400, {"message": "title, artist and year are required"})

    song = _load_song_by_identity(title, artist, year)
    if not song:
        return _response(event, 404, {"message": "Song not found"})

    song_id = song.get("song_id") or _song_id(song["title"], song["artist"], song["year"])

    try:
        subs_table.put_item(
            Item={
                "user_email": user_email,
                "song_id": song_id,
                "title": song.get("title", ""),
                "artist": song.get("artist", ""),
                "year": song.get("year", ""),
                "album": song.get("album", ""),
                "image_key": song.get("image_key", ""),
                "img_url": song.get("img_url") or song.get("image_url") or "",
                "subscribed_at": _now_iso(),
            },
            ConditionExpression="attribute_not_exists(song_id)",
        )
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return _response(event, 409, {"message": "Song already subscribed"})
        raise

    return _response(event, 201, {"message": "Subscription created", "song_id": song_id})


def _route_subscriptions_delete(event):
    data = _json_body(event)
    user_email = _clean(data.get("user") or data.get("user_email") or data.get("email"))

    if not user_email:
        return _response(event, 400, {"message": "user_email is required"})

    song_id = _clean(data.get("song_id"))
    if not song_id:
        title = _clean(data.get("title"))
        artist = _clean(data.get("artist"))
        year = _clean(data.get("year"))
        if title and artist and year:
            song_id = _song_id(title, artist, year)

    if not song_id:
        return _response(event, 400, {"message": "song_id (or title + artist + year) is required"})

    subs_table.delete_item(Key={"user_email": user_email, "song_id": song_id})
    return _response(event, 200, {"message": "Subscription removed"})


def lambda_handler(event, context):
    method = _method(event)
    path = _path(event)

    try:
        parts = path.split("/")
        if len(parts) > 2 and parts[2] in {"api", "health", "register", "login", "music", "subscriptions", "subscription", "subscribe"}:
            path = "/" + "/".join(parts[2:]).rstrip("/")
    except Exception:
        pass

    try:
        if method == "OPTIONS":
            return _response(event, 200, {"message": "ok"})

        if path in {"/", "/health", "/api/health"} and method == "GET":
            return _response(
                event,
                200,
                {
                    "status": "ok",
                    "service": "music-subscription-lambda",
                    "aws_region": AWS_REGION,
                    "tables": {
                        "users": USERS_TABLE_NAME,
                        "music": MUSIC_TABLE_NAME,
                        "subscriptions": SUBSCRIPTIONS_TABLE_NAME,
                    },
                    "images_bucket": S3_BUCKET_NAME,
                },
            )

        if path in {"/register", "/api/register"} and method == "POST":
            return _route_register(event)

        if path in {"/login", "/api/login"} and method == "POST":
            return _route_login(event)

        if path in {"/music", "/api/music"} and method == "GET":
            return _route_music(event)

        if path in {"/subscription", "/subscriptions", "/api/subscriptions", "/subscribe"}:
            if method == "GET":
                return _route_subscriptions_get(event)
            if method == "POST":
                return _route_subscriptions_post(event)
            if method == "DELETE":
                return _route_subscriptions_delete(event)

        return _response(event, 404, {"message": "Route not found"})

    except NoCredentialsError:
        return _response(event, 503, {"message": "AWS credentials not found for Lambda execution role."})
    except EndpointConnectionError:
        return _response(event, 503, {"message": "Unable to connect to AWS endpoint."})
    except ClientError as error:
        code = error.response.get("Error", {}).get("Code", "ClientError")
        status = 503 if code == "ResourceNotFoundException" else 500
        return _response(event, status, {"message": "AWS/DynamoDB request failed.", "code": code})
