const std = @import("std");
const builtin = @import("builtin");

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

pub fn main() !void {
    var debug_alloc_impl: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc_impl.deinit() == .leak) @panic("LEAK");
    const gpa = if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) debug_alloc_impl.allocator() else std.heap.smp_allocator;

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

    var musicbrainz_cache_arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer musicbrainz_cache_arena_impl.deinit();
    const musicbrainz_cache_arena = musicbrainz_cache_arena_impl.allocator();

    const MusicBrainzCache = struct {
        id: ?[]const u8 = null,
        mebi_album_listen_url: ?[]const u8 = null,
        mebi_song_url: ?[]const u8 = null,
        artist_url: ?[]const u8 = null,
    };
    var musicbrainz_cache: MusicBrainzCache = .{};

    var song_link_cache_arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer song_link_cache_arena_impl.deinit();
    const song_link_cache_arena = song_link_cache_arena_impl.allocator();

    const SongLinkCache = struct {
        id: ?[]const u8 = null,
        mebi_listen_url: ?[]const u8 = null,
    };
    var song_link_cache: SongLinkCache = .{};

    var loop_arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer loop_arena_impl.deinit();
    const loop_arena = loop_arena_impl.allocator();
    while (run) {
        var clear: bool = true;

        defer std.Thread.sleep(std.time.ns_per_s * 5);
        defer _ = loop_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 });

        var response_writer: std.Io.Writer.Allocating = .init(loop_arena);
        defer response_writer.deinit();

        defer if (clear) {
            rpc_client.setPresence(null) catch unreachable;
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
                std.debug.print("GOT REQUEST ERROR {s} !! WAA\n", .{@tagName(request.status)});
                continue;
            }
        }

        // std.debug.print("response: {s}\n", .{response_writer.written()});

        std.debug.print("got response\n", .{});

        const sessions: []Session = std.json.parseFromSliceLeaky([]Session, loop_arena, response_writer.written(), .{
            .ignore_unknown_fields = true,
            .duplicate_field_behavior = .use_last,
            .allocate = .alloc_always,
        }) catch |err| {
            std.debug.print("FAILED TO PARSE, FUCK, GOT {s}\n", .{@errorName(err)});
            continue;
        };

        const session = find_session: {
            for (sessions) |*session| {
                if (std.mem.eql(u8, session.UserId, config.value.jellyfin_user_id) and session.NowPlayingItem != null and !session.PlayState.IsPaused) {
                    break :find_session session;
                }
            } else {
                std.debug.print("found no sessions for user {s}", .{config.value.jellyfin_user_id});
            }

            continue;
        };

        const now_playing = session.NowPlayingItem.?;

        // Reset the cache if it's invalid
        if (musicbrainz_cache.id != null and !std.mem.eql(u8, musicbrainz_cache.id.?, now_playing.Id)) {
            _ = musicbrainz_cache_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 });
            musicbrainz_cache = .{};
        }
        if (song_link_cache.id != null and !std.mem.eql(u8, song_link_cache.id.?, now_playing.Id)) {
            _ = song_link_cache_arena_impl.reset(.{ .retain_with_limit = 1024 * 1024 });
            song_link_cache = .{};
        }

        const mebi_artist = get_artist: {
            if (now_playing.ArtistItems) |artist_items| {
                for (artist_items) |*artist| {
                    break :get_artist artist;
                }
            }
            std.debug.print("no artists found\n", .{});

            break :get_artist null;
        };

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

        std.debug.print("parsed response\n", .{});

        const lyrics: ?Lyrics = if (now_playing.HasLyrics != null and now_playing.HasLyrics.?) get_lyrics: {
            const lyrics_uri = composeUri(base_uri, try std.fmt.allocPrint(loop_arena, "/Audio/{s}/Lyrics", .{now_playing.Id}));

            response_writer.clearRetainingCapacity();

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = lyrics_uri },
                .method = .GET,
                .decompress_buffer = &decompress_buffer,
                .redirect_buffer = &redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                std.debug.print("GOT LYRICS REQUEST ERROR {s} !! WAA\n", .{@tagName(request.status)});
                break :get_lyrics null;
            }

            const lyrics = std.json.parseFromSliceLeaky(Lyrics, loop_arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                std.debug.print("GOT LYRICS PARSE ERROR {s} !! WAA\n", .{@errorName(err)});
                break :get_lyrics null;
            };

            break :get_lyrics lyrics;
        } else null;

        const album_item: ?Item = get_album_item: {
            const album_id = now_playing.AlbumId orelse break :get_album_item null;

            const lyrics_uri = composeUri(base_uri, try std.fmt.allocPrint(loop_arena, "/Users/{s}/Items/{s}", .{ config.value.jellyfin_user_id, album_id }));

            response_writer.clearRetainingCapacity();

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = lyrics_uri },
                .method = .GET,
                .decompress_buffer = &decompress_buffer,
                .redirect_buffer = &redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                std.debug.print("GOT ALBUM ITEM REQUEST ERROR {s} !! WAA\n", .{@tagName(request.status)});
                break :get_album_item null;
            }

            const item = std.json.parseFromSliceLeaky(Item, loop_arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                std.debug.print("GOT ALBUM ITEM PARSE ERROR {s} !! WAA\n", .{@errorName(err)});
                break :get_album_item null;
            };

            break :get_album_item item;
        };

        var album_url: ?[]const u8 = null;

        get_album_info: {
            if (album_item) |album| {
                if (album.ProviderIds) |provider_ids| {
                    if (provider_ids.MusicBrainzAlbum) |musicbrainz_album| {
                        album_url = try std.fmt.allocPrint(loop_arena, "https://musicbrainz.org/release/{s}", .{musicbrainz_album});

                        // if cache is already valid
                        if (musicbrainz_cache.id != null and std.mem.eql(u8, now_playing.Id, musicbrainz_cache.id.?)) {
                            break :get_album_info;
                        }

                        response_writer.clearRetainingCapacity();

                        std.debug.print("music brainz request\n", .{});

                        const request = try http_client.fetch(.{
                            .headers = jellyfin_headers,
                            .location = .{
                                .url = try std.fmt.allocPrint(loop_arena, "https://musicbrainz.org/ws/2/release/{s}?inc=url-rels+recordings+artist-credits&fmt=json", .{musicbrainz_album}),
                            },
                            .method = .GET,
                            .decompress_buffer = &decompress_buffer,
                            .redirect_buffer = &redirect_buffer,
                            .response_writer = &response_writer.writer,
                        });
                        if (request.status != .ok) {
                            std.debug.print("GOT ALBUM ITEM REQUEST ERROR {s} !! WAA\n", .{@tagName(request.status)});
                            break :get_album_info;
                        }

                        const item: MusicBrainzRelease = std.json.parseFromSliceLeaky(MusicBrainzRelease, loop_arena, response_writer.written(), .{
                            .allocate = .alloc_always,
                            .ignore_unknown_fields = true,
                            .duplicate_field_behavior = .use_last,
                        }) catch |err| {
                            std.debug.print("GOT ALBUM ITEM PARSE ERROR {s} !! WAA\n", .{@errorName(err)});
                            break :get_album_info;
                        };

                        musicbrainz_cache = .{
                            .id = try musicbrainz_cache_arena.dupe(u8, now_playing.Id),
                        };

                        for (item.@"artist-credit") |artist| {
                            musicbrainz_cache.artist_url = try musicbrainz_cache_arena.dupe(u8, try std.fmt.allocPrint(
                                loop_arena,
                                "https://musicbrainz.org/artist/{s}",
                                .{artist.artist.id},
                            ));
                            break;
                        }

                        var found_rank: u8 = std.math.maxInt(u8);
                        for (item.relations) |relation| {
                            const relation_type = std.meta.stringToEnum(MusicBrainzRelease.Relation.Type, relation.type) orelse continue;

                            const rank = @intFromEnum(relation_type);

                            if (rank < found_rank) {
                                musicbrainz_cache.mebi_album_listen_url = try musicbrainz_cache_arena.dupe(u8, relation.url.resource);
                                found_rank = rank;
                            }
                        }

                        if (now_playing.IndexNumber) |track_index| {
                            for (item.media) |media| {
                                if (now_playing.ParentIndexNumber == null or now_playing.ParentIndexNumber.? == 0 or now_playing.ParentIndexNumber.? == media.position) {
                                    for (media.tracks) |track| {
                                        if (track.position == track_index) {
                                            musicbrainz_cache.mebi_song_url = try musicbrainz_cache_arena.dupe(u8, try std.fmt.allocPrint(
                                                loop_arena,
                                                "https://musicbrainz.org/release/{s}/disc/{d}#{s}",
                                                .{ musicbrainz_album, media.position, track.id },
                                            ));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        const current_lyric: ?[]const u8 = get_lyric: {
            if (session.PlayState.PositionTicks == null) {
                break :get_lyric null;
            }

            if (lyrics) |song_lyrics| {
                std.mem.sort(
                    Lyric,
                    song_lyrics.Lyrics,
                    {},
                    struct {
                        pub fn lt(context: void, lhs: Lyric, rhs: Lyric) bool {
                            _ = context;

                            return lhs.Start orelse 0 < rhs.Start orelse 0;
                        }
                    }.lt,
                );

                var current_lyric: ?[]const u8 = null;
                for (song_lyrics.Lyrics) |lyric| {
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

        get_song_link: {
            // if cache is already valid
            if (song_link_cache.id != null and std.mem.eql(u8, now_playing.Id, song_link_cache.id.?)) {
                break :get_song_link;
            }

            // need existing url
            if (musicbrainz_cache.mebi_album_listen_url == null) {
                break :get_song_link;
            }

            response_writer.clearRetainingCapacity();

            var uri: std.Uri = try .parse("https://api.song.link/v1-alpha.1/links");
            uri.query = .{ .raw = try std.fmt.allocPrint(loop_arena, "url={s}", .{musicbrainz_cache.mebi_album_listen_url.?}) };

            std.debug.print("song link request: {f}\n", .{uri});

            const request = try http_client.fetch(.{
                .headers = jellyfin_headers,
                .location = .{ .uri = uri },
                .method = .GET,
                .decompress_buffer = &decompress_buffer,
                .redirect_buffer = &redirect_buffer,
                .response_writer = &response_writer.writer,
            });
            if (request.status != .ok) {
                std.debug.print("GOT SONG LINK REQUEST ERROR {s} !! WAA\n", .{@tagName(request.status)});
                break :get_song_link;
            }

            const item: SongLinkResponse = std.json.parseFromSliceLeaky(SongLinkResponse, loop_arena, response_writer.written(), .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            }) catch |err| {
                std.debug.print("GOT SONG LINK PARSE ERROR {s} !! WAA\n", .{@errorName(err)});
                break :get_song_link;
            };

            song_link_cache = .{
                .id = try song_link_cache_arena.dupe(u8, now_playing.Id),
                .mebi_listen_url = try song_link_cache_arena.dupe(u8, item.pageUrl),
            };
        }

        clear = false;

        const presence: RichPresence.Packet.Presence = .{
            .assets = .{
                .large_image = try .createFromFormat("{f}", .{try imageUrl(loop_arena, base_uri, now_playing.Id)}),
                .large_text = .createNullable(now_playing.Album),
                .large_url = .createNullable(album_url),
                .small_image = if (mebi_artist) |artist| try .createFromFormat("{f}", .{try imageUrl(loop_arena, base_uri, artist.Id)}) else null,
                .small_text = if (mebi_artist) |artist| .createNullable(artist.Name) else null,
                .small_url = .createNullable(musicbrainz_cache.artist_url),
            },
            .buttons = if (song_link_cache.mebi_listen_url orelse musicbrainz_cache.mebi_album_listen_url) |listen_url| &.{
                .{
                    .label = .create("Listen"),
                    .url = .create(listen_url),
                },
                // .{
                //     .label = .create("Lyrics"),
                //     .url = .create("https://example.com/track_lyrics"),
                // },
            } else null,
            .name = if (mebi_artist) |artist| .createNullable(artist.Name) else .create("Jellyfin"),
            .state = .createNullable(current_lyric),
            .state_url = null,
            .details = .create(now_playing.Name),
            .details_url = .createNullable(musicbrainz_cache.mebi_song_url),
            .party = null,
            .secrets = null,
            .status_display_type = .name,
            .type = .listening,
            .timestamps = timestamps,
        };
        try rpc_client.setPresence(presence);
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
