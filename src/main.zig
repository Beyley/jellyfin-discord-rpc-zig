const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

const OscClient = @import("osc").Client;
const RichPresence = @import("rpc");

const Config = struct {
    client_id: []const u8,
    jellyfin_base_url: []const u8,
    jellyfin_api_key: []const u8,
    jellyfin_user_id: []const u8,

    const config_path = "config.json";

    pub fn read(gpa: std.mem.Allocator) !std.json.Parsed(Config) {
        const config_str = std.fs.cwd().readFileAlloc(gpa, config_path, 1024 * 10) catch |err| {
            if (err == std.fs.File.OpenError.FileNotFound) {
                try std.fs.cwd().writeFile(.{
                    .data =
                    \\{"client_id": "", "jellyfin_base_url": "", "jellyfin_api_key": "", "jellyfin_user_id": ""}
                    ,
                    .sub_path = config_path,
                });
            }

            return error.ConfigCreatedEditPlease;
        };
        defer gpa.free(config_str);

        return try std.json.parseFromSlice(Config, gpa, config_str, .{
            .allocate = .alloc_always,
        });
    }
};

fn composeUri(
    base_uri: std.Uri,
    path: []const u8,
) std.Uri {
    var composed = base_uri;
    composed.path = .{
        .raw = path,
    };
    return composed;
}

fn imageUrl(gpa: std.mem.Allocator, base_uri: std.Uri, id: []const u8) !std.Uri {
    // {jellyfin_url}/Items/{item_id}/Images/Primary
    const path = try std.fmt.allocPrint(gpa, "/Items/{s}/Images/Primary", .{id});
    errdefer gpa.free(path);

    var composed = base_uri;
    composed.path = .{
        .raw = path,
    };
    return composed;
}

fn streamUrl(gpa: std.mem.Allocator, base_uri: std.Uri, id: []const u8) !std.Uri {
    const path = try std.fmt.allocPrint(gpa, "/Audio/{s}/Stream.ogg", .{id});
    errdefer gpa.free(path);

    var composed = base_uri;
    composed.path = .{
        .raw = path,
    };
    composed.query = .{ .raw = "maxAudioChannels=2&audioSampleRate=44100&static=true" };
    return composed;
}

fn trim(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
}

const PlayState = struct {
    PositionTicks: ?i64 = null,
    IsPaused: bool,
};

const ArtistItem = struct {
    Name: ?[]const u8 = null,
    Id: []const u8,
};

const Lyric = struct {
    Text: []const u8,
    Start: ?i64 = null,
};

const Lyrics = struct {
    Lyrics: []Lyric,
};

const Item = struct {
    pub const ItemType = enum(i32) {
        AggregateFolder,
        Audio,
        AudioBook,
        BasePluginFolder,
        Book,
        BoxSet,
        Channel,
        ChannelFolderItem,
        CollectionFolder,
        Episode,
        Folder,
        Genre,
        ManualPlaylistsFolder,
        Movie,
        LiveTvChannel,
        LiveTvProgram,
        MusicAlbum,
        MusicArtist,
        MusicGenre,
        MusicVideo,
        Person,
        Photo,
        PhotoAlbum,
        Playlist,
        PlaylistsFolder,
        Program,
        Recording,
        Season,
        Series,
        Studio,
        Trailer,
        TvChannel,
        TvProgram,
        UserRootFolder,
        UserView,
        Video,
        Year,
        _,
    };

    pub const ItemMediaType = enum(i32) {
        Unknown,
        Video,
        Audio,
        Photo,
        Book,
    };

    Name: []const u8,
    Id: []const u8,
    HasLyrics: ?bool = null,
    RunTimeTicks: ?i64 = null,
    Type: ItemType,
    MediaType: ItemMediaType,
    ArtistItems: ?[]ArtistItem = null,
    Album: ?[]const u8 = null,
    AlbumId: ?[]const u8 = null,
    IndexNumber: ?usize = null,
    ParentIndexNumber: ?usize = null,
    ProviderIds: ?struct {
        MusicBrainzAlbum: ?[]const u8 = null,
    } = null,
};

const Session = struct {
    PlayState: PlayState,
    UserId: []const u8,
    NowPlayingItem: ?Item = null,
    NowPlayingQueueFullItems: ?[]Item,
};

const MusicBrainzRelease = struct {
    pub const Relation = struct {
        pub const Type = enum(u8) {
            @"free streaming",
            @"download for free",
            streaming,
            @"purchase for download",
        };

        type: []const u8,
        url: struct {
            resource: []const u8,
        },
    };

    pub const Media = struct {
        @"track-count": usize,
        tracks: []struct {
            position: usize,
            id: []const u8,
            title: []const u8,
        },
        position: usize,
    };

    pub const ArtistCredit = struct {
        artist: struct {
            id: []const u8,
        },
    };

    media: []Media,
    relations: []Relation,
    @"artist-credit": []ArtistCredit,
};

pub const SongLinkResponse = struct {
    pageUrl: []const u8,
};

var run = true;

const osc_escape_char = '¦';
const osc_replacement = '|';

fn oscEscape(str: []u8) void {
    std.mem.replaceScalar(u8, str, osc_escape_char, osc_replacement);
}

const Caches = struct {
    const max_age = 30;

    const MusicBrainz = struct {
        mebi_album_listen_url: ?[]const u8,
        mebi_song_url: ?[]const u8,
        mebi_artist_url: ?[]const u8,

        age: usize,
        accessed: bool,

        pub fn deinit(self: MusicBrainz, gpa: std.mem.Allocator) void {
            if (self.mebi_album_listen_url) |album_listen_url| {
                gpa.free(album_listen_url);
            }
            if (self.mebi_song_url) |song_url| {
                gpa.free(song_url);
            }
            if (self.mebi_artist_url) |artist_url| {
                gpa.free(artist_url);
            }
        }
    };
    const SongLink = struct {
        listen_url: []const u8,

        age: usize,
        accessed: bool,

        pub fn deinit(self: SongLink, gpa: std.mem.Allocator) void {
            gpa.free(self.listen_url);
        }
    };
    const Jellyfin = struct {
        mebi_album_name: ?[]const u8,
        mebi_musicbrainz_album_id: ?[]const u8,

        age: usize,
        accessed: bool,

        pub fn deinit(self: Jellyfin, gpa: std.mem.Allocator) void {
            if (self.mebi_album_name) |album_name| {
                gpa.free(album_name);
            }
            if (self.mebi_musicbrainz_album_id) |musicbrainz_album_id| {
                gpa.free(musicbrainz_album_id);
            }
        }
    };

    mebi_last_id: ?[]const u8,

    musicbrainz: std.StringArrayHashMapUnmanaged(MusicBrainz),
    song_link: std.StringArrayHashMapUnmanaged(SongLink),
    jellyfin: std.StringArrayHashMapUnmanaged(Jellyfin),

    pub fn get(self: *Caches, name: @Type(.enum_literal), id: []const u8) ?@TypeOf(@as(@TypeOf(@field(self, @tagName(name))).KV, undefined).value) {
        const ptr = @field(self, @tagName(name)).getPtr(id) orelse return null;

        ptr.accessed = true;

        return ptr.*;
    }

    pub fn contains(self: *Caches, name: @Type(.enum_literal), id: []const u8) bool {
        const ptr = @field(self, @tagName(name)).getPtr(id) orelse return false;

        ptr.accessed = true;

        return true;
    }

    pub fn tick(self: *Caches, gpa: std.mem.Allocator, now_playing: Item) void {
        // Don't tick if the song hasn't changed
        if (self.mebi_last_id) |last_id| {
            if (std.mem.eql(u8, now_playing.Id, last_id)) {
                return;
            }
        }

        self.mebi_last_id = now_playing.Id;

        inline for (&.{ &self.musicbrainz, &self.song_link, &self.jellyfin }) |map| {
            var i: usize = 0;
            while (i < map.count()) {
                const key = map.keys()[i];
                const value = &map.values()[i];

                if (value.accessed) {
                    value.age = 0;
                    value.accessed = false;
                    continue;
                }

                value.age += 1;

                if (value.age > max_age) {
                    log.debug("Key {s} got too old, removing", .{key});

                    value.deinit(gpa);
                    map.orderedRemoveAt(i);
                    gpa.free(key);
                    continue;
                }

                i += 1;
            }
        }
    }
};

const ParsedItem = struct {
    song_id: []const u8,
    song_title: []const u8,
    song_image: []const u8,
    mebi_song_url: ?[]const u8,

    mebi_album_title: ?[]const u8,
    mebi_album_url: ?[]const u8,

    mebi_artist_name: ?[]const u8,
    mebi_artist_image: ?[]const u8,
    mebi_artist_url: ?[]const u8,

    mebi_stream_url: ?[]const u8,
    mebi_listen_url: ?[]const u8,

    mebi_lyrics: ?[]Lyric,

    pub fn fromJellyfin(
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
        config: Config,
        caches: *Caches,
        base_uri: std.Uri,
        response_writer: *std.Io.Writer.Allocating,
        http_client: *std.http.Client,
        jellyfin_headers: std.http.Client.Request.Headers,
        decompress_buffer: []u8,
        redirect_buffer: []u8,
        item: Item,
    ) !ParsedItem {
        const mebi_artist: ?*ArtistItem = get_artist: {
            if (item.ArtistItems) |artist_items| {
                for (artist_items) |*artist| {
                    break :get_artist artist;
                }
            }
            log.debug("no artists found for {s} ({s})", .{ item.Name, item.Id });

            break :get_artist null;
        };

        const mebi_lyrics: ?Lyrics = if (item.HasLyrics != null and item.HasLyrics.?) get_lyrics: {
            const lyrics_uri = composeUri(base_uri, try std.fmt.allocPrint(arena, "/Audio/{s}/Lyrics", .{item.Id}));

            response_writer.clearRetainingCapacity();

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = lyrics_uri },
                .method = .GET,
                .decompress_buffer = decompress_buffer,
                .redirect_buffer = redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                log.err("GOT LYRICS REQUEST ERROR {s} !! WAA", .{@tagName(request.status)});
                break :get_lyrics null;
            }

            const lyrics = std.json.parseFromSliceLeaky(Lyrics, arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                log.err("GOT LYRICS PARSE ERROR {s} !! WAA", .{@errorName(err)});
                break :get_lyrics null;
            };

            break :get_lyrics lyrics;
        } else null;

        get_album_item: {
            if (caches.contains(.jellyfin, item.Id)) {
                break :get_album_item;
            }

            const album_id = item.AlbumId orelse break :get_album_item;

            const lyrics_uri = composeUri(base_uri, try std.fmt.allocPrint(arena, "/Users/{s}/Items/{s}", .{ config.jellyfin_user_id, album_id }));

            response_writer.clearRetainingCapacity();

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = lyrics_uri },
                .method = .GET,
                .decompress_buffer = decompress_buffer,
                .redirect_buffer = redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                log.err("GOT ALBUM ITEM REQUEST ERROR {s} !! WAA", .{@tagName(request.status)});
                break :get_album_item;
            }

            const parsed_album_item = std.json.parseFromSliceLeaky(Item, arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                log.err("GOT ALBUM ITEM PARSE ERROR {s} !! WAA", .{@errorName(err)});
                break :get_album_item;
            };

            var mebi_musicbrainz_album_id_gpa: ?[]const u8 = null;
            errdefer gpa.free(mebi_musicbrainz_album_id_gpa orelse &.{});
            if (parsed_album_item.ProviderIds) |provider_ids| {
                if (provider_ids.MusicBrainzAlbum) |musicbrainz_album| {
                    mebi_musicbrainz_album_id_gpa = try gpa.dupe(u8, musicbrainz_album);
                }
            }

            try caches.jellyfin.putNoClobber(gpa, try gpa.dupe(u8, item.Id), .{
                .mebi_album_name = try gpa.dupe(u8, parsed_album_item.Name),
                .mebi_musicbrainz_album_id = mebi_musicbrainz_album_id_gpa,

                .accessed = true,
                .age = 0,
            });

            log.debug("Put {s} ({s}) into jellyfin cache", .{ item.Name, item.Id });
        }

        var mebi_album_url: ?[]const u8 = null;

        get_album_info: {
            if (caches.get(.jellyfin, item.Id)) |cache_entry| {
                const musicbrainz_album = cache_entry.mebi_musicbrainz_album_id orelse break :get_album_info;

                mebi_album_url = try std.fmt.allocPrint(arena, "https://musicbrainz.org/release/{s}", .{musicbrainz_album});

                // if cache is already valid, we don't need to do any work
                if (caches.contains(.musicbrainz, item.Id)) {
                    break :get_album_info;
                }

                response_writer.clearRetainingCapacity();

                log.debug("sent music brainz request for {s}", .{item.Id});

                const request = try http_client.fetch(.{
                    .headers = jellyfin_headers,
                    .location = .{
                        .url = try std.fmt.allocPrint(arena, "https://musicbrainz.org/ws/2/release/{s}?inc=url-rels+recordings+artist-credits&fmt=json", .{musicbrainz_album}),
                    },
                    .method = .GET,
                    .decompress_buffer = decompress_buffer,
                    .redirect_buffer = redirect_buffer,
                    .response_writer = &response_writer.writer,
                });
                if (request.status != .ok) {
                    log.err("GOT ALBUM ITEM REQUEST ERROR {s} !! WAA", .{@tagName(request.status)});
                    break :get_album_info;
                }

                const parsed_release_item: MusicBrainzRelease = std.json.parseFromSliceLeaky(MusicBrainzRelease, arena, response_writer.written(), .{
                    .allocate = .alloc_always,
                    .ignore_unknown_fields = true,
                    .duplicate_field_behavior = .use_last,
                }) catch |err| {
                    log.err("GOT ALBUM ITEM PARSE ERROR {s} !! WAA", .{@errorName(err)});
                    break :get_album_info;
                };

                var mebi_artist_url_gpa: ?[]const u8 = null;
                errdefer gpa.free(mebi_artist_url_gpa orelse &.{});
                for (parsed_release_item.@"artist-credit") |artist| {
                    mebi_artist_url_gpa = try std.fmt.allocPrint(
                        gpa,
                        "https://musicbrainz.org/artist/{s}",
                        .{artist.artist.id},
                    );
                    break;
                }

                var mebi_album_listen_url_arena: ?[]const u8 = null;
                var found_rank: u8 = std.math.maxInt(u8);
                for (parsed_release_item.relations) |relation| {
                    const relation_type = std.meta.stringToEnum(MusicBrainzRelease.Relation.Type, relation.type) orelse continue;

                    const rank = @intFromEnum(relation_type);

                    if (rank < found_rank) {
                        mebi_album_listen_url_arena = relation.url.resource;
                        found_rank = rank;
                    }
                }

                var mebi_song_url_gpa: ?[]const u8 = null;
                errdefer gpa.free(mebi_song_url_gpa orelse &.{});
                if (item.IndexNumber) |track_index| {
                    for (parsed_release_item.media) |media| {
                        if (item.ParentIndexNumber == null or item.ParentIndexNumber.? == 0 or item.ParentIndexNumber.? == media.position) {
                            for (media.tracks) |track| {
                                if (track.position == track_index) {
                                    mebi_song_url_gpa = try std.fmt.allocPrint(
                                        gpa,
                                        "https://musicbrainz.org/release/{s}/disc/{d}#{s}",
                                        .{ musicbrainz_album, media.position, track.id },
                                    );
                                    break;
                                }
                            }
                        }
                    }
                }

                const mebi_album_listen_url_gpa = if (mebi_album_listen_url_arena) |mebi_album_listen_url| try gpa.dupe(u8, mebi_album_listen_url) else null;
                errdefer gpa.free(mebi_album_listen_url_gpa orelse &.{});

                try caches.musicbrainz.putNoClobber(gpa, try gpa.dupe(u8, item.Id), .{
                    .mebi_song_url = mebi_song_url_gpa,
                    .mebi_album_listen_url = mebi_album_listen_url_gpa,
                    .mebi_artist_url = mebi_artist_url_gpa,

                    .age = 0,
                    .accessed = true,
                });
                log.debug("put {s} ({s}) into musicbrainz cache", .{ item.Name, item.Id });
            }
        }

        get_song_link: {
            // if cache is already valid, nothing to do
            if (caches.contains(.song_link, item.Id)) {
                break :get_song_link;
            }

            // need existing url
            const musicbrainz_item = caches.get(.musicbrainz, item.Id) orelse break :get_song_link;
            const musicbrainz_album_listen_url = musicbrainz_item.mebi_album_listen_url orelse break :get_song_link;

            response_writer.clearRetainingCapacity();

            var uri: std.Uri = try .parse("https://api.song.link/v1-alpha.1/links");
            uri.query = .{ .raw = try std.fmt.allocPrint(arena, "url={s}", .{musicbrainz_album_listen_url}) };

            log.debug("song link request: {f}", .{uri});

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = uri },
                .method = .GET,
                .decompress_buffer = decompress_buffer,
                .redirect_buffer = redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                log.err("GOT SONG LINK REQUEST ERROR {s} !! WAA", .{@tagName(request.status)});
                break :get_song_link;
            }

            const song_link_item: SongLinkResponse = std.json.parseFromSliceLeaky(SongLinkResponse, arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                log.err("GOT SONG LINK PARSE ERROR {s} !! WAA", .{@errorName(err)});
                break :get_song_link;
            };

            const listen_url = try gpa.dupe(u8, song_link_item.pageUrl);
            errdefer gpa.free(listen_url);

            try caches.song_link.putNoClobber(gpa, try gpa.dupe(u8, item.Id), .{
                .listen_url = listen_url,
                .age = 0,
                .accessed = true,
            });
            log.debug("put {s} ({s}) into songlink cache", .{ item.Name, item.Id });
        }

        const mebi_listen_url: ?[]const u8 = get_song_url: {
            if (caches.get(.song_link, item.Id)) |cache_entry| {
                break :get_song_url cache_entry.listen_url;
            }

            if (caches.get(.musicbrainz, item.Id)) |cache_entry| {
                break :get_song_url cache_entry.mebi_album_listen_url;
            }

            break :get_song_url null;
        };

        const mebi_artist_image = if (mebi_artist) |artist| try std.fmt.allocPrint(arena, "{f}", .{try imageUrl(arena, base_uri, artist.Id)}) else "";

        return .{
            .song_id = item.Id,
            .song_title = item.Name,
            .song_image = try std.fmt.allocPrint(
                arena,
                "{f}",
                .{try imageUrl(arena, base_uri, item.Id)},
            ),
            .mebi_song_url = if (caches.get(.musicbrainz, item.Id)) |cache_entry| cache_entry.mebi_song_url else null,

            .mebi_album_title = if (caches.get(.jellyfin, item.Id)) |album| album.mebi_album_name else null,
            .mebi_album_url = mebi_album_url,

            .mebi_artist_name = if (mebi_artist) |artist| artist.Name else null,
            .mebi_artist_image = mebi_artist_image,
            .mebi_artist_url = if (caches.get(.musicbrainz, item.Id)) |cache_entry| cache_entry.mebi_artist_url else null,

            .mebi_stream_url = try std.fmt.allocPrint(arena, "{f}", .{try streamUrl(arena, base_uri, item.Id)}),
            .mebi_listen_url = mebi_listen_url,

            .mebi_lyrics = if (mebi_lyrics) |lyrics| lyrics.Lyrics else null,
        };
    }
};

fn constructOscItem(gpa: std.mem.Allocator, item: ParsedItem) ![]const u8 {
    _ = gpa; // autofix
    _ = item; // autofix
}

fn sendOsc(osc_client: *OscClient, osc_buf: []u8, path: []const u8, string: []const u8) void {
    osc_client.sendMessage(osc_buf, .{
        .address = path,
        .arguments = &.{
            .{ .s = string },
        },
    }) catch return;
}

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc_impl.deinit() == .leak) @panic("LEAK");
    const gpa = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) debug_alloc_impl.allocator() else std.heap.smp_allocator;

    var osc_client: OscClient = .{
        .port = 1025,
    };
    try osc_client.connect(false, "127.0.0.1");

    const config = try Config.read(gpa);
    defer config.deinit();

    const base_uri: std.Uri = try .parse(config.value.jellyfin_base_url);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);

    const sessions_uri = get_session_uri: {
        const sessions_uri = composeUri(base_uri, "/Sessions");
        // sessions_uri.query = .{ .raw = "activeWithinSeconds=60" };
        break :get_session_uri sessions_uri;
    };
    try sessions_uri.format(&stdout_writer.interface);
    try stdout_writer.interface.flush();

    const jellyfin_headers: std.http.Client.Request.Headers = .{
        .authorization = .{ .override = config.value.jellyfin_api_key },
        .user_agent = .{ .override = "jellyfin-discord-rpc-zig/1.0" },
    };

    var rpc_client = try RichPresence.init(gpa, &ready);
    defer rpc_client.deinit();

    var thread = try std.Thread.spawn(.{}, runRpc, .{ rpc_client, config.value });
    defer {
        rpc_client.stop();
        thread.join();
    }

    var http_client: std.http.Client = .{
        .allocator = gpa,
    };
    defer http_client.deinit();

    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var redirect_buffer: [8192]u8 = undefined;

    var caches: Caches = .{
        .mebi_last_id = null,
        .musicbrainz = .empty,
        .song_link = .empty,
        .jellyfin = .empty,
    };

    var osc_buf: [4096]u8 = undefined;

    var last_discord_send: i64 = std.time.timestamp();

    var loop_arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer loop_arena_impl.deinit();
    const loop_arena = loop_arena_impl.allocator();
    while (run) {
        var clear: bool = true;

        defer std.Thread.sleep(std.time.ns_per_s * 0.5);
        defer _ = loop_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 });

        const now = std.time.timestamp();

        var response_writer: std.Io.Writer.Allocating = .init(loop_arena);
        defer response_writer.deinit();

        defer if (clear) {
            sendOsc(&osc_client, &osc_buf, "/PlaybackState", "-1");

            if (now - last_discord_send > 7) {
                rpc_client.setPresence(null) catch unreachable;
                last_discord_send = now;
            }
        };

        {
            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = sessions_uri },
                .method = .GET,
                .decompress_buffer = &decompress_buffer,
                .redirect_buffer = &redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                log.err("GOT REQUEST ERROR {s} !! WAA", .{@tagName(request.status)});
                continue;
            }
        }

        // log.debug("response: {s}", .{response_writer.written()});

        log.debug("got response", .{});

        const sessions: []Session = std.json.parseFromSliceLeaky([]Session, loop_arena, response_writer.written(), .{
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .use_last,
            .allocate = .alloc_always,
        }) catch |err| {
            log.err("FAILED TO PARSE, FUCK, GOT {s}", .{@errorName(err)});
            continue;
        };

        const session = find_session: {
            for (sessions) |*session| {
                if (std.mem.eql(u8, session.UserId, config.value.jellyfin_user_id) and session.NowPlayingItem != null and !session.PlayState.IsPaused) {
                    break :find_session session;
                }
            } else {
                log.err("found no sessions for user {s}", .{config.value.jellyfin_user_id});
            }

            continue;
        };

        const now_playing = session.NowPlayingItem.?;

        caches.tick(gpa, now_playing);

        const parsed_item: ParsedItem = try .fromJellyfin(
            gpa,
            loop_arena,
            config.value,
            &caches,
            base_uri,
            &response_writer,
            &http_client,
            jellyfin_headers,
            &decompress_buffer,
            &redirect_buffer,
            now_playing,
        );

        log.debug("parsed response", .{});

        const now_milliseconds = std.time.milliTimestamp();

        const timestamps: ?RichPresence.Packet.Presence.Timestamps = get_timestamps: {
            if (session.PlayState.PositionTicks == null or now_playing.RunTimeTicks == null) {
                break :get_timestamps null;
            }

            const start = now_milliseconds - @divFloor(session.PlayState.PositionTicks.?, 10000);

            break :get_timestamps .{
                .start = @intCast(start),
                .end = @intCast(start + @divFloor(now_playing.RunTimeTicks.?, 10000)),
            };
        };

        const current_lyric: ?[]const u8 = get_lyric: {
            if (session.PlayState.PositionTicks == null) {
                break :get_lyric null;
            }

            if (parsed_item.mebi_lyrics) |song_lyrics| {
                std.mem.sort(
                    Lyric,
                    song_lyrics,
                    {},
                    struct {
                        pub fn lt(context: void, lhs: Lyric, rhs: Lyric) bool {
                            _ = context;

                            return lhs.Start orelse 0 < rhs.Start orelse 0;
                        }
                    }.lt,
                );

                var current_lyric: ?[]const u8 = null;
                for (song_lyrics) |lyric| {
                    if (lyric.Start == null) {
                        continue;
                    }

                    if (lyric.Start.? <= session.PlayState.PositionTicks.?) {
                        current_lyric = lyric.Text;
                        if (trim(lyric.Text).len == 0) {
                            current_lyric = null;
                        }
                    } else {
                        break;
                    }
                }
                break :get_lyric if (current_lyric) |curr_lyric| try std.fmt.allocPrint(loop_arena, "🎵 \"{s}\" 🎵", .{curr_lyric}) else null;
            }

            break :get_lyric null;
        };

        clear = false;

        {
            // sendOsc(&osc_client, &osc_buf, "/SongTitle", now_playing.Name);
            // sendOsc(&osc_client, &osc_buf, "/AlbumTitle", now_playing.Album orelse "");
            // sendOsc(&osc_client, &osc_buf, "/SongImage", try std.fmt.allocPrint(loop_arena, "{f}", .{try imageUrl(loop_arena, base_uri, now_playing.Id)}));
            // sendOsc(
            //     &osc_client,
            //     &osc_buf,
            //     "/ArtistImage",
            //     if (mebi_artist) |artist| try std.fmt.allocPrint(loop_arena, "{f}", .{try imageUrl(loop_arena, base_uri, artist.Id)}) else "",
            // );
            // sendOsc(&osc_client, &osc_buf, "/ArtistName", if (mebi_artist) |artist| artist.Name orelse "" else "");

            // sendOsc(&osc_client, &osc_buf, "/SongURL", musicbrainz_cache.mebi_song_url orelse "");
            // sendOsc(&osc_client, &osc_buf, "/ArtistURL", musicbrainz_cache.artist_url orelse "");
            // sendOsc(&osc_client, &osc_buf, "/AlbumURL", album_url orelse "");

            // sendOsc(&osc_client, &osc_buf, "/CurrentLyric", current_lyric orelse "");

            // sendOsc(&osc_client, &osc_buf, "/StreamURL", try std.fmt.allocPrint(loop_arena, "{f}", .{try streamUrl(loop_arena, base_uri, now_playing.Id)}));

            // if (timestamps) |timestamp| {
            //     sendOsc(&osc_client, &osc_buf, "/StartTime", try std.fmt.allocPrint(loop_arena, "{d}", .{timestamp.start orelse @as(i65, -1)}));
            //     sendOsc(&osc_client, &osc_buf, "/EndTime", try std.fmt.allocPrint(loop_arena, "{d}", .{timestamp.end orelse @as(i65, -1)}));
            // } else {
            //     sendOsc(&osc_client, &osc_buf, "/StartTime", "-1");
            //     sendOsc(&osc_client, &osc_buf, "/EndTime", "-1");
            // }

            // sendOsc(&osc_client, &osc_buf, "/PlaybackState", "1");

            // std.debug.print("OSC SENT\n", .{});
        }

        if (now - last_discord_send > 7) {
            const presence: RichPresence.Packet.Presence = .{
                .assets = .{
                    .large_image = try .createFromFormat("{f}", .{try imageUrl(loop_arena, base_uri, now_playing.Id)}),
                    .large_text = .createNullable(now_playing.Album),
                    .large_url = .createNullable(parsed_item.mebi_album_url),
                    .small_image = .createNullable(parsed_item.mebi_artist_image),
                    .small_text = .createNullable(parsed_item.mebi_artist_name),
                    .small_url = .createNullable(parsed_item.mebi_artist_url),
                },
                .buttons = if (parsed_item.mebi_listen_url) |listen_url| &.{
                    .{
                        .label = .create("Listen"),
                        .url = .create(listen_url),
                    },
                    // .{
                    //     .label = .create("Lyrics"),
                    //     .url = .create("https://example.com/track_lyrics"),
                    // },
                } else null,
                .name = if (parsed_item.mebi_artist_name) |artist_name| .createNullable(artist_name) else .create("Jellyfin"),
                .state = .createNullable(current_lyric),
                .state_url = null,
                .details = .create(now_playing.Name),
                .details_url = .createNullable(parsed_item.mebi_song_url),
                .party = null,
                .secrets = null,
                .status_display_type = .name,
                .type = .listening,
                .timestamps = timestamps,
            };
            try rpc_client.setPresence(presence);

            last_discord_send = now;
        }
    }

    rpc_client.stop();
}

fn ready(rpc_client: *RichPresence) anyerror!void {
    _ = rpc_client; // autofix
}

fn runRpc(rpc_client: *RichPresence, config: Config) void {
    rpc_client.run(.{
        .client_id = config.client_id,
    }) catch unreachable;
}
