const std = @import("std");

pub const Authentication = @This();

credentials: Credentials,

challenge_buffer: []u8,
response_buffer: []u8,

state: union(enum) {
    unauthorized,
    basic,
    digest: struct {
        challenge: digest.Challenge,
        authorizer: digest.Authorizer,
    },
} = .unauthorized,

pub const Scheme = enum {
    basic,
    digest,
};

pub const Credentials = struct {
    user: []const u8,
    password: []const u8,
};

pub fn init(
    gpa: std.mem.Allocator,
    credentials: Credentials,
    opts: struct {
        challenge_buffer_len: usize = 4096,
        response_buffer_len: usize = 4096,
    },
) std.mem.Allocator.Error!Authentication {
    const challenge_buffer = try gpa.alloc(u8, opts.challenge_buffer_len);
    errdefer gpa.free(challenge_buffer);
    const response_buffer = try gpa.alloc(u8, opts.response_buffer_len);
    errdefer gpa.free(response_buffer);

    return .{
        .credentials = credentials,
        .challenge_buffer = challenge_buffer,
        .response_buffer = response_buffer,
    };
}

pub fn deinit(self: *Authentication, gpa: std.mem.Allocator) void {
    gpa.free(self.challenge_buffer);
    gpa.free(self.response_buffer);
}

pub fn reset(self: *Authentication) void {
    self.state = .unauthorized;
    @memset(self.challenge_buffer, 0);
    @memset(self.response_buffer, 0);
}

pub const SetChallengeError = error{ Overflow, UnsupportedScheme } || digest.Challenge.ParseError;

/// Challenge with WWW-Authenticate header value.
/// header only needs to be valid for the call.
/// This function is illegal to call if the authentication state is not unauthorized.
pub fn set_challenge(self: *Authentication, io: std.Io, header: []const u8) SetChallengeError!void {
    std.debug.assert(self.state == .unauthorized);
    var header_iter = std.mem.splitSequence(u8, header, " ");
    const scheme_str = header_iter.first();
    const scheme: Scheme =
        if (std.ascii.eqlIgnoreCase(scheme_str, "Digest"))
            .digest
        else if (std.ascii.eqlIgnoreCase(scheme_str, "Basic"))
            .basic
        else
            return SetChallengeError.UnsupportedScheme;
    switch (scheme) {
        .basic => {
            self.state = .basic;
        },
        .digest => {
            const header_copy = std.fmt.bufPrint(self.challenge_buffer, "{s}", .{header}) catch return SetChallengeError.Overflow;
            const challenge = try digest.Challenge.parse(header_copy);
            const authorizer = digest.Authorizer.init(io, &challenge);
            self.state = .{ .digest = .{ .challenge = challenge, .authorizer = authorizer } };
        },
    }
}

pub const RequestInfo = struct {
    /// Request method (HTTP/1.1 Section 5.1.2)
    method: []const u8,
    /// Request URI (HTTP/1.1).
    uri: []const u8,
    /// Request body contents.
    body: []const u8,
};

pub const AuthorizeError = error{Overflow};

/// Authorize a request.
/// Returns the value for the Authorization header.
/// Returned value is valid until next call to authorize.
pub fn authorize(self: *Authentication, request_info: RequestInfo) AuthorizeError![]const u8 {
    var writer = std.Io.Writer.fixed(self.response_buffer);
    switch (self.state) {
        .unauthorized => unreachable,
        .basic => basic.authorize(self.credentials, &writer) catch return AuthorizeError.Overflow,
        .digest => |*state| {
            const response = state.authorizer.authorize(&state.challenge, self.credentials, request_info);
            response.write(&writer) catch return AuthorizeError.Overflow;
        },
    }
    return writer.buffered();
}

pub const basic = struct {
    /// Authorize Basic authentication with given credentials.
    /// Returns Overflow error if the length of user plus password plus 1 is more than 2048.
    /// Writes Authorize header response to writer.
    pub fn authorize(
        credentials: Credentials,
        writer: *std.Io.Writer,
    ) (error{Overflow} || std.Io.Writer.Error)!void {
        var aux_buffer: [2048]u8 = undefined;
        if (credentials.user.len + 1 + credentials.password.len > aux_buffer.len) return error.Overflow;

        var aux_writer = std.Io.Writer.fixed(&aux_buffer);
        aux_writer.writeAll(credentials.user) catch unreachable;
        aux_writer.writeByte(':') catch unreachable;
        aux_writer.writeAll(credentials.password) catch unreachable;

        try writer.writeAll("Basic ");
        try std.base64.standard.Encoder.encodeWriter(writer, aux_writer.buffered());
    }

    test "authorize basic auth 1" {
        var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer writer.deinit();

        try basic.authorize(.{ .user = "test", .password = "test" }, &writer.writer);
        try std.testing.expectEqualStrings("Basic dGVzdDp0ZXN0", writer.written());
    }

    test "authorize basic auth 2" {
        var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer writer.deinit();

        try basic.authorize(.{ .user = "al", .password = "ice" }, &writer.writer);
        try std.testing.expectEqualStrings("Basic YWw6aWNl", writer.written());
    }
};

pub const digest = struct {
    pub const Challenge = struct {
        realm: []const u8,
        domain: ?[]const u8,
        nonce: []const u8,
        @"opaque": ?[]const u8,
        stale: ?bool,
        algorithm_string: ?[]const u8,
        algorithm: ?Algorithm,
        qop_options: QOPOptions,

        pub const ParseError = error{
            MissingEqualsSign,
            MissingNonce,
            MissingRealm,
            InvalidStale,
            UnsupportedAlgorithm,
            UnsupportedHeaderFormat,
            UnsupportedMethod,
            UnsupportedQOP,
        };

        /// Parse WWW-Authenticate header.
        /// - header must remain valid for lifetime of Challenge
        pub fn parse(header: []const u8) ParseError!Challenge {
            const trim_quoted_string = struct {
                inline fn trim_quoted_string(slice: []const u8) []const u8 {
                    if (slice.len < 2) return slice;
                    const is_quoted = slice[0] == '"' and slice[slice.len - 1] == '"';
                    return if (is_quoted) slice[1 .. slice.len - 1] else slice;
                }
            }.trim_quoted_string;

            if (!std.mem.startsWith(u8, header, "Digest ")) return ParseError.UnsupportedMethod;
            // Escaping is not supported and may break authentication.
            if (std.mem.indexOfScalar(u8, header, '\\') != null) return ParseError.UnsupportedHeaderFormat;

            var realm: ?[]const u8 = null;
            var domain: ?[]const u8 = null;
            var nonce: ?[]const u8 = null;
            var @"opaque": ?[]const u8 = null;
            var stale: ?bool = null;
            var algorithm_string: ?[]const u8 = null;
            var algorithm: ?Algorithm = null;
            var qop: QOPOptions = .{};

            var params = ParamIterator{ .data = header[7..] };

            while (try params.next()) |param| {
                const name = std.meta.stringToEnum(enum {
                    realm,
                    domain,
                    nonce,
                    @"opaque",
                    stale,
                    algorithm,
                    qop,
                }, param.name) orelse continue;

                switch (name) {
                    .realm => {
                        realm = trim_quoted_string(param.value);
                    },
                    .domain => {
                        domain = trim_quoted_string(param.value);
                    },
                    .nonce => {
                        nonce = trim_quoted_string(param.value);
                    },
                    .@"opaque" => {
                        @"opaque" = trim_quoted_string(param.value);
                    },
                    .stale => {
                        const stale_unquoted = trim_quoted_string(param.value);
                        if (std.ascii.eqlIgnoreCase(stale_unquoted, "true")) {
                            stale = true;
                        } else if (std.ascii.eqlIgnoreCase(stale_unquoted, "false")) {
                            stale = false;
                        } else {
                            return ParseError.InvalidStale;
                        }
                    },
                    .algorithm => {
                        algorithm_string = param.value;

                        const algorithm_unquoted = trim_quoted_string(param.value);
                        if (std.ascii.eqlIgnoreCase(algorithm_unquoted, "MD5")) {
                            algorithm = .MD5;
                        } else if (std.ascii.eqlIgnoreCase(algorithm_unquoted, "MD5-sess")) {
                            algorithm = .@"MD5-sess";
                        } else {
                            return ParseError.UnsupportedAlgorithm;
                        }
                    },
                    .qop => {
                        var qop_parts = std.mem.splitScalar(u8, trim_quoted_string(param.value), ',');
                        while (qop_parts.next()) |qop_part| {
                            const qop_option = std.mem.trim(u8, qop_part, " \t");
                            if (std.ascii.eqlIgnoreCase(qop_option, "auth")) {
                                qop.auth = true;
                            } else if (std.ascii.eqlIgnoreCase(qop_option, "auth-int")) {
                                qop.@"auth-int" = true;
                            } else {
                                return ParseError.UnsupportedQOP;
                            }
                        }
                    },
                }
            }

            return Challenge{
                .realm = realm orelse return ParseError.MissingRealm,
                .domain = domain,
                .nonce = nonce orelse return ParseError.MissingNonce,
                .@"opaque" = @"opaque",
                .stale = stale,
                .algorithm_string = algorithm_string,
                .algorithm = algorithm,
                .qop_options = qop,
            };
        }

        const Param = struct {
            name: []const u8,
            value: []const u8,

            /// Parses parameter name value pair.
            /// For example: algorithm="md5" -> Param { .name = "algorithm", .value = "\"md5\"" }
            pub inline fn parse(slice: []const u8) ParseError!Param {
                const slice_trimmed = std.mem.trim(u8, slice, " \t");
                const eq_pos = std.mem.indexOfScalar(u8, slice_trimmed, '=') orelse return ParseError.MissingEqualsSign;
                return Param{
                    .name = slice_trimmed[0..eq_pos],
                    .value = slice_trimmed[eq_pos + 1 ..],
                };
            }
        };

        const ParamIterator = struct {
            data: []const u8,
            /// Starting position of next expected part.
            pos: usize = 0,

            fn next(self: *ParamIterator) !?Param {
                // If pos < self.data.len then there are one or more parts left to emit.
                // If pos == self.data.len then there is one empty part left to emit.
                // If pos > self.data.len then there are no parts to emit (beyond end).
                if (self.pos > self.data.len) return null;

                const start_pos = self.pos;
                var state: enum { normal, quoted } = .normal;

                while (self.pos < self.data.len) : (self.pos += 1) {
                    const c = self.data[self.pos];
                    if (c == '\\') {
                        self.pos += 1;
                    } else if (c == '"') {
                        state = switch (state) {
                            .normal => .quoted,
                            .quoted => .normal,
                        };
                    } else if (c == ',' and state == .normal) {
                        defer self.pos += 1; // Next iteration should start at character after the ','.
                        return try Param.parse(self.data[start_pos..self.pos]);
                    }
                } else {
                    std.debug.assert(self.pos == self.data.len);

                    defer self.pos += 1; // Next iteration should start at character after the ','.
                    return try Param.parse(self.data[start_pos..]);
                }
            }
        };

        test "ParamIterator empty slice" {
            var it = ParamIterator{ .data = "" };
            try std.testing.expectError(ParseError.MissingEqualsSign, it.next());
        }

        test "ParamIterator comma storm" {
            var it = ParamIterator{ .data = ",,," };
            try std.testing.expectError(ParseError.MissingEqualsSign, it.next());
        }

        test "ParamIterator trailing comma" {
            var it = ParamIterator{ .data = "nonce=\"abc\"," };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expectError(ParseError.MissingEqualsSign, it.next());
        }

        test "ParamIterator single part" {
            var it = ParamIterator{ .data = "nonce=\"abc\"" };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expect(try it.next() == null);
        }

        test "ParamIterator basic split" {
            var it = ParamIterator{ .data = "realm=\"test\",nonce=\"abc\"" };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "realm", .value = "\"test\"" });
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expect(try it.next() == null);
        }

        test "ParamIterator quoted comma" {
            var it = ParamIterator{ .data = "realm=\"te,st\",nonce=\"abc\"" };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "realm", .value = "\"te,st\"" });
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expect(try it.next() == null);
        }

        test "ParamIterator escaped quote" {
            var it = ParamIterator{ .data = "realm=\"te\\\"st\",nonce=\"abc\"" };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "realm", .value = "\"te\\\"st\"" });
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expect(try it.next() == null);
        }

        test "ParamIterator escaped comma in quotes" {
            var it = ParamIterator{ .data = "realm=\"te\\,st\",nonce=\"abc\"" };
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "realm", .value = "\"te\\,st\"" });
            try std.testing.expectEqualDeep((try it.next()).?, Param{ .name = "nonce", .value = "\"abc\"" });
            try std.testing.expect(try it.next() == null);
        }
    };

    test "Challenge.parse rejects non-digest challenge" {
        try std.testing.expectError(
            Challenge.ParseError.UnsupportedMethod,
            Challenge.parse("Basic realm=\"x\""),
        );
    }

    test "Challenge.parse rejects missing realm" {
        try std.testing.expectError(
            Challenge.ParseError.MissingRealm,
            Challenge.parse("Digest nonce=\"n\""),
        );
    }

    test "Challenge.parse rejects missing nonce" {
        try std.testing.expectError(
            Challenge.ParseError.MissingNonce,
            Challenge.parse("Digest realm=\"r\""),
        );
    }

    test "Challenge.parse rejects unsupported algorithm" {
        try std.testing.expectError(
            Challenge.ParseError.UnsupportedAlgorithm,
            Challenge.parse("Digest realm=\"r\", nonce=\"n\", algorithm=SHA-256"),
        );
    }

    test "Challenge.parse rejects unsupported qop" {
        try std.testing.expectError(
            Challenge.ParseError.UnsupportedQOP,
            Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=\"foo\""),
        );
    }

    test "Challenge.parse without algorithm or qop" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\""),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = null,
                .algorithm = null,
                .qop_options = .{ .auth = false, .@"auth-int" = false },
            },
        );
    }

    test "Challenge.parse with algorithm=MD5 (unquoted)" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\", algorithm=MD5"),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = "MD5",
                .algorithm = .MD5,
                .qop_options = .{ .auth = false, .@"auth-int" = false },
            },
        );
    }

    test "Challenge.parse with algorithm=\"MD5-sess\" (quoted)" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\", algorithm=\"MD5-sess\""),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = "\"MD5-sess\"",
                .algorithm = .@"MD5-sess",
                .qop_options = .{ .auth = false, .@"auth-int" = false },
            },
        );
    }

    test "Challenge.parse with qop=auth" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=auth"),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = null,
                .algorithm = null,
                .qop_options = .{ .auth = true, .@"auth-int" = false },
            },
        );
    }

    test "Challenge.parse with qop=\"auth-int\"" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\""),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = null,
                .algorithm = null,
                .qop_options = .{ .auth = false, .@"auth-int" = true },
            },
        );
    }

    test "Challenge.parse with qop=\"auth,auth-int\"" {
        try std.testing.expectEqualDeep(
            try Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=\"auth,auth-int\""),
            Challenge{
                .realm = "r",
                .domain = null,
                .nonce = "n",
                .@"opaque" = null,
                .stale = null,
                .algorithm_string = null,
                .algorithm = null,
                .qop_options = .{ .auth = true, .@"auth-int" = true },
            },
        );
    }

    pub const Authorizer = struct {
        cnonce: ?[32]u8,
        nonce_count: u32 = 0,

        /// Initialize DigestAuth based on initial challenge.
        pub fn init(io: std.Io, challenge: *const Challenge) Authorizer {
            const cnonce_required =
                challenge.algorithm == .@"MD5-sess" or
                challenge.qop_options.auth or
                challenge.qop_options.@"auth-int";
            const cnonce: ?[32]u8 = if (cnonce_required) generate_cnonce(io) else null;

            return Authorizer{ .cnonce = cnonce, .nonce_count = 0 };
        }

        /// Authorize a request.
        /// Returns response to authorize request.
        /// - challenge must outlive the ChallengeResponse
        /// - credentials.user must outlive the ChallengeResponse
        /// - request.uri must outlive the ChallengeResponse
        pub fn authorize(
            self: *Authorizer,
            challenge: *const Challenge,
            credentials: Credentials,
            request: RequestInfo,
        ) ChallengeResponse {
            const algorithm = challenge.algorithm orelse .MD5;

            // QOP selection:
            // 1. Use "auth" if selected.
            // 2. Use "auth-int" otherwise if selected.
            // 3. Use unspecified if both are not selected.
            const qop: QOP = if (challenge.qop_options.auth)
                .auth
            else if (challenge.qop_options.@"auth-int")
                .@"auth-int"
            else
                .unspecified;

            var ha1: [32]u8 = undefined;
            hash(&.{ credentials.user, ":", challenge.realm, ":", credentials.password }, &ha1);

            switch (algorithm) {
                .@"MD5-sess" => {
                    hash(&.{ &ha1, ":", challenge.nonce, ":", &self.cnonce.? }, &ha1);
                },
                else => {},
            }

            var ha2: [32]u8 = undefined;
            switch (qop) {
                .@"auth-int" => {
                    var hashed_entity_body: [32]u8 = undefined;
                    hash(&.{request.body}, &hashed_entity_body);
                    hash(&.{ request.method, ":", request.uri, ":", &hashed_entity_body }, &ha2);
                },
                .auth, .unspecified => {
                    hash(&.{ request.method, ":", request.uri }, &ha2);
                },
            }

            var response: [32]u8 = undefined;
            var nonce_count_string: [8]u8 = undefined;
            switch (qop) {
                .auth, .@"auth-int" => {
                    defer self.nonce_count = self.nonce_count +| 1;

                    const out_buf = std.fmt.bufPrint(&nonce_count_string, "{x:0>8}", .{self.nonce_count}) catch unreachable;
                    std.debug.assert(out_buf.len == nonce_count_string.len);

                    hash(&.{ &ha1, ":", challenge.nonce, ":", &nonce_count_string, ":", &self.cnonce.?, ":", @tagName(qop), ":", &ha2 }, &response);
                },
                .unspecified => {
                    hash(&.{ &ha1, ":", challenge.nonce, ":", &ha2 }, &response);
                },
            }

            return ChallengeResponse{
                .user = credentials.user,
                .realm = challenge.realm,
                .nonce = challenge.nonce,
                .request_uri = request.uri,
                .response = response,
                .algorithm = challenge.algorithm_string,
                .cnonce = self.cnonce,
                .qop = qop,
                .nonce_count_string = nonce_count_string,
                .@"opaque" = challenge.@"opaque",
            };
        }

        inline fn generate_cnonce(io: std.Io) [32]u8 {
            var random: [16]u8 = undefined;
            io.randomSecure(&random) catch unreachable;

            var cnonce: [32]u8 = undefined;
            const out_buf = std.fmt.bufPrint(&cnonce, "{x}", .{&random}) catch unreachable;
            std.debug.assert(out_buf.len == cnonce.len);

            return cnonce;
        }

        /// Hash one or more slices using MD5 and format as hex string.
        inline fn hash(data: []const []const u8, out: *[32]u8) void {
            std.debug.assert(data.len > 0);

            var md5: std.crypto.hash.Md5 = std.crypto.hash.Md5.init(.{});
            var hash_out: [16]u8 = undefined;
            for (data) |slice| md5.update(slice);
            md5.final(&hash_out);

            const out_buf = std.fmt.bufPrint(out, "{x}", .{&hash_out}) catch unreachable;
            std.debug.assert(out_buf.len == out.len);
        }
    };

    pub const ChallengeResponse = struct {
        user: []const u8,
        realm: []const u8,
        nonce: []const u8,
        request_uri: []const u8,
        response: [32]u8,
        algorithm: ?[]const u8,
        cnonce: ?[32]u8,
        qop: QOP,
        nonce_count_string: [8]u8,
        @"opaque": ?[]const u8,

        /// Write response to provided writer.
        pub fn write(self: *const ChallengeResponse, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("Digest ");
            try writer.print("username=\"{s}\"", .{self.user});
            try writer.print(",realm=\"{s}\"", .{self.realm});
            try writer.print(",nonce=\"{s}\"", .{self.nonce});
            try writer.print(",uri=\"{s}\"", .{self.request_uri});
            try writer.print(",response=\"{s}\"", .{self.response});
            // Some servers expect that we mirror the value for algorithm exactly.
            // Even though quoting the algorithm value is technically not supported
            // at all some servers will send it anyway, and expect us to return it
            // unchanged.
            if (self.algorithm) |algorithm| {
                try writer.print(",algorithm={s}", .{algorithm});
            }

            switch (self.qop) {
                .auth, .@"auth-int" => {
                    try writer.print(",cnonce=\"{s}\"", .{&self.cnonce.?});
                    try writer.print(",qop={s}", .{@tagName(self.qop)});
                    try writer.print(",nc={s}", .{self.nonce_count_string});
                },
                .unspecified => {},
            }

            if (self.@"opaque") |opaque_val| {
                try writer.print(",opaque=\"{s}\"", .{opaque_val});
            }
        }
    };

    fn test_digest_auth(
        user: []const u8,
        password: []const u8,
        www_authenticate: []const u8,
        method: []const u8,
        uri: []const u8,
        body: []const u8,
        expected: []const u8,
    ) !void {
        const challenge = try Challenge.parse(www_authenticate);
        var authorizer = Authorizer.init(std.testing.io, &challenge);
        const response = authorizer.authorize(
            &challenge,
            .{ .user = user, .password = password },
            .{ .method = method, .uri = uri, .body = body },
        );

        var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer writer.deinit();
        try response.write(&writer.writer);

        try std.testing.expectEqualStrings(expected, writer.written());
    }

    test "Auth qop selection (auth preferred when both present)" {
        const challenge = try Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=\"auth,auth-int\"");
        var authorizer = Authorizer.init(std.testing.io, &challenge);
        const response = authorizer.authorize(
            &challenge,
            .{ .user = "u", .password = "p" },
            .{ .method = "GET", .uri = "/", .body = "" },
        );
        try std.testing.expectEqual(QOP.auth, response.qop);
        try std.testing.expect(authorizer.cnonce != null);
    }

    test "Auth qop selection (auth-int when only auth-int)" {
        const challenge = try Challenge.parse("Digest realm=\"r\", nonce=\"n\", qop=\"auth-int\"");
        var authorizer = Authorizer.init(std.testing.io, &challenge);
        const response = authorizer.authorize(
            &challenge,
            .{ .user = "u", .password = "p" },
            .{ .method = "GET", .uri = "/", .body = "" },
        );
        try std.testing.expectEqual(QOP.@"auth-int", response.qop);
        try std.testing.expect(authorizer.cnonce != null);
    }

    test "authorize live555 digest auth sample (no qop)" {
        try test_digest_auth(
            "test",
            "test",
            "Digest realm=\"LIVE555 Streaming Media\", nonce=\"c5b6707025bd9992a00165b2fd3e7e66\"",
            "DESCRIBE",
            "rtsp://100.10.10.10:554/Sms=100.unicast",
            "",
            "Digest username=\"test\",realm=\"LIVE555 Streaming Media\",nonce=\"c5b6707025bd9992a00165b2fd3e7e66\",uri=\"rtsp://100.10.10.10:554/Sms=100.unicast\",response=\"4ff62fbfe604d0893d8a74bed60c69d4\"",
        );
    }

    test "authorize axis gstreamer digest auth sample (no qop)" {
        try test_digest_auth(
            "test",
            "test",
            "Digest realm=\"AXIS_000000000000\", nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\", stale=FALSE",
            "DESCRIBE",
            "rtsp://192.168.99.99/axis-media/media.amp",
            "",
            "Digest username=\"test\",realm=\"AXIS_000000000000\",nonce=\"0000002eY58201830228ecf0d17659e11c069f0b57392e\",uri=\"rtsp://192.168.99.99/axis-media/media.amp\",response=\"ef817a98e5e03b73b5841ee82abfc000\"",
        );
    }

    test "authorize digest auth sample with algorithm=MD5 and opaque" {
        try test_digest_auth(
            "test",
            "test",
            "Digest realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",opaque=\"\",stale=FALSE,algorithm=MD5",
            "OPTIONS",
            "rtsp://192.168.99.99:554/s0",
            "",
            "Digest username=\"test\",realm=\"Please log in with a valid username\",nonce=\"1459175f5bd9528e432f5de06df01d4c\",uri=\"rtsp://192.168.99.99:554/s0\",response=\"74f4185272f1e748e897328b248e3c72\",algorithm=MD5,opaque=\"\"",
        );
    }

    test "authorize digest auth sample with algorithm=\"MD5\" (quoted mirror)" {
        try test_digest_auth(
            "test",
            "test",
            "Digest realm=\"RTSP UVC G4 Bullet (9BB2)\", nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\", algorithm=\"MD5\"",
            "DESCRIBE",
            "rtsp://192.168.99.99/s0",
            "",
            "Digest username=\"test\",realm=\"RTSP UVC G4 Bullet (9BB2)\",nonce=\"cd1c0cd09edf806f29dd17e516d2f7dd\",uri=\"rtsp://192.168.99.99/s0\",response=\"56b91ca07a894f8d5cf10c4c96fa99b2\",algorithm=\"MD5\"",
        );
    }

    test "authorize streaming server digest auth sample (no qop)" {
        try test_digest_auth(
            "test",
            "test",
            "Digest realm=\"Streaming Server\", nonce=\"bdbb6157b3534eab0811efb3bc7571d0\"",
            "DESCRIBE",
            "rtsp://100.10.0.10:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_11&streamindex=2",
            "",
            "Digest username=\"test\",realm=\"Streaming Server\",nonce=\"bdbb6157b3534eab0811efb3bc7571d0\",uri=\"rtsp://100.10.0.10:4543/Media/Live/Normal/S_00000000-0000-0000-0000-000000000000?camera=C_11&streamindex=2\",response=\"d7e03e2e020dd1d3de52a27e24a964cf\"",
        );
    }

    pub const Algorithm = enum {
        MD5,
        @"MD5-sess",
    };

    pub const QOPOptions = struct {
        auth: bool = false,
        @"auth-int": bool = false,
    };

    pub const QOP = enum {
        auth,
        @"auth-int",
        unspecified,
    };
};

test {
    std.testing.refAllDecls(@This());
}
