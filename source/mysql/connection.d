﻿module mysql.connection;

// Publically import rest of package for backwards compatability.
// These public imports will eventually be phased out.
public import mysql.common;
public import mysql.result;
public import mysql.protocol.commands;
public import mysql.protocol.constants;
public import mysql.protocol.extra_types;
public import mysql.protocol.packet_helpers;
public import mysql.protocol.packets;
debug(MYSQL_INTEGRATION_TESTS)
{
    public import mysql.test.common;
    public import mysql.test.integration;
    public import mysql.test.regression;
}

version(Have_vibe_d_core)
{
    static if(__traits(compiles, (){ import vibe.core.net; } ))
        import vibe.core.net;
    else
        static assert(false, "mysql-native can't find Vibe.d's 'vibe.core.net'.");
}

import std.algorithm;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.exception;
import std.range;
import std.socket;
import std.stdio;
import std.string;
import std.traits;
import std.variant;

immutable SvrCapFlags defaultClientFlags =
        SvrCapFlags.OLD_LONG_PASSWORD | SvrCapFlags.ALL_COLUMN_FLAGS |
        SvrCapFlags.WITH_DB | SvrCapFlags.PROTOCOL41 |
        SvrCapFlags.SECURE_CONNECTION;// | SvrCapFlags.MULTI_STATEMENTS |
        //SvrCapFlags.MULTI_RESULTS;

/**
 * A struct representing a database connection.
 *
 * The Connection is responsible for handshaking with the server to establish
 * authentication. It then passes client preferences to the server, and
 * subsequently is the channel for all command packets that are sent, and all
 * response packets received.
 *
 * Uncompressed packets consist of a 4 byte header - 3 bytes of length, and one
 * byte as a packet number. Connection deals with the headers and ensures that
 * packet numbers are sequential.
 *
 * The initial packet is sent by the server - essentially a 'hello' packet
 * inviting login. That packet has a sequence number of zero. That sequence
 * number is the incremented by client and server packets through the handshake
 * sequence.
 *
 * After login all further sequences are initialized by the client sending a
 * command packet with a zero sequence number, to which the server replies with
 * zero or more packets with sequential sequence numbers.
 */
class Connection
{
package:
    enum OpenState
    {
        /// We have not yet connected to the server, or have sent QUIT to the
        /// server and closed the connection
        notConnected,
        /// We have connected to the server and parsed the greeting, but not
        /// yet authenticated
        connected,
        /// We have successfully authenticated against the server, and need to
        /// send QUIT to the server when closing the connection
        authenticated
    }
    OpenState   _open;
    MySQLSocket _socket;

    SvrCapFlags _sCaps, _cCaps;
    uint    _sThread;
    ushort  _serverStatus;
    ubyte   _sCharSet, _protocol;
    string  _serverVersion;

    string _host, _user, _pwd, _db;
    ushort _port;

    MySQLSocketType _socketType;

    OpenSocketCallbackPhobos _openSocketPhobos;
    OpenSocketCallbackVibeD  _openSocketVibeD;

    // This tiny thing here is pretty critical. Pay great attention to it's maintenance, otherwise
    // you'll get the dreaded "packet out of order" message. It, and the socket connection are
    // the reason why most other objects require a connection object for their construction.
    ubyte _cpn; /// Packet Number in packet header. Serial number to ensure correct
                /// ordering. First packet should have 0
    @property ubyte pktNumber()   { return _cpn; }
    void bumpPacket()       { _cpn++; }
    void resetPacket()      { _cpn = 0; }

    version(Have_vibe_d_core) {} else
    pure const nothrow invariant()
    {
        assert(_socketType != MySQLSocketType.vibed);
    }

    ubyte[] getPacket()
    {
        scope(failure) kill();

        ubyte[4] header;
        _socket.read(header);
        // number of bytes always set as 24-bit
        uint numDataBytes = (header[2] << 16) + (header[1] << 8) + header[0];
        enforceEx!MYXProtocol(header[3] == pktNumber, "Server packet out of order");
        bumpPacket();

        ubyte[] packet = new ubyte[numDataBytes];
        _socket.read(packet);
        assert(packet.length == numDataBytes, "Wrong number of bytes read");
        return packet;
    }

    void send(ubyte[] packet)
    in
    {
        assert(packet.length > 4); // at least 1 byte more than header
    }
    body
    {
        _socket.write(packet);
    }

    void send(ubyte[] header, ubyte[] data)
    in
    {
        assert(header.length == 4 || header.length == 5/*command type included*/);
    }
    body
    {
        _socket.write(header);
        if(data.length)
            _socket.write(data);
    }

    void sendCmd(T)(CommandType cmd, T[] data)
    in
    {
        // Internal thread states. Clients shouldn't use this
        assert(cmd != CommandType.SLEEP);
        assert(cmd != CommandType.CONNECT);
        assert(cmd != CommandType.TIME);
        assert(cmd != CommandType.DELAYED_INSERT);
        assert(cmd != CommandType.CONNECT_OUT);

        // Deprecated
        assert(cmd != CommandType.CREATE_DB);
        assert(cmd != CommandType.DROP_DB);
        assert(cmd != CommandType.TABLE_DUMP);

        // cannot send more than uint.max bytes. TODO: better error message if we try?
        assert(data.length <= uint.max);
    }
    out
    {
        // at this point we should have sent a command
        assert(pktNumber == 1);
    }
    body
    {
        if(!_socket.connected)
        {
            if(cmd == CommandType.QUIT)
                return; // Don't bother reopening connection just to quit

            _open = OpenState.notConnected;
            connect(_clientCapabilities);
        }

        resetPacket();

        ubyte[] header;
        header.length = 4 /*header*/ + 1 /*cmd*/;
        header.setPacketHeader(pktNumber, cast(uint)data.length +1/*cmd byte*/);
        header[4] = cmd;
        bumpPacket();

        send(header, cast(ubyte[])data);
    }

    OKErrorPacket getCmdResponse(bool asString = false)
    {
        auto okp = OKErrorPacket(getPacket());
        enforcePacketOK(okp);
        _serverStatus = okp.serverStatus;
        return okp;
    }

    ubyte[] buildAuthPacket(ubyte[] token)
    in
    {
        assert(token.length == 20);
    }
    body
    {
        ubyte[] packet;
        packet.reserve(4/*header*/ + 4 + 4 + 1 + 23 + _user.length+1 + token.length+1 + _db.length+1);
        packet.length = 4 + 4 + 4; // create room for the beginning headers that we set rather than append

        // NOTE: we'll set the header last when we know the size

        // Set the default capabilities required by the client
        _cCaps.packInto(packet[4..8]);

        // Request a conventional maximum packet length.
        1.packInto(packet[8..12]);

        packet ~= 33; // Set UTF-8 as default charSet

        // There's a statutory block of zero bytes here - fill them in.
        foreach(i; 0 .. 23)
            packet ~= 0;

        // Add the user name as a null terminated string
        foreach(i; 0 .. _user.length)
            packet ~= _user[i];
        packet ~= 0; // \0

        // Add our calculated authentication token as a length prefixed string.
        assert(token.length <= ubyte.max);
        if(_pwd.length == 0)  // Omit the token if the account has no password
            packet ~= 0;
        else
        {
            packet ~= cast(ubyte)token.length;
            foreach(i; 0 .. token.length)
                packet ~= token[i];
        }

        // Add the default database as a null terminated string
        foreach(i; 0 .. _db.length)
            packet ~= _db[i];
        packet ~= 0; // \0

        // The server sent us a greeting with packet number 0, so we send the auth packet
        // back with the next number.
        packet.setPacketHeader(pktNumber);
        bumpPacket();
        return packet;
    }

    void consumeServerInfo(ref ubyte[] packet)
    {
        scope(failure) kill();

        _sCaps = cast(SvrCapFlags)packet.consume!ushort(); // server_capabilities (lower bytes)
        _sCharSet = packet.consume!ubyte(); // server_language
        _serverStatus = packet.consume!ushort(); //server_status
        _sCaps += cast(SvrCapFlags)(packet.consume!ushort() << 16); // server_capabilities (upper bytes)
        _sCaps |= SvrCapFlags.OLD_LONG_PASSWORD; // Assumed to be set since v4.1.1, according to spec

        enforceEx!MYX(_sCaps & SvrCapFlags.PROTOCOL41, "Server doesn't support protocol v4.1");
        enforceEx!MYX(_sCaps & SvrCapFlags.SECURE_CONNECTION, "Server doesn't support protocol v4.1 connection");
    }

    ubyte[] parseGreeting()
    {
        scope(failure) kill();

        ubyte[] packet = getPacket();

        if (packet.length > 0 && packet[0] == ResultPacketMarker.error)
        {
            auto okp = OKErrorPacket(packet);
            enforceEx!MYX(!okp.error, "Connection failure: " ~ cast(string) okp.message);
        }

        _protocol = packet.consume!ubyte();

        _serverVersion = packet.consume!string(packet.countUntil(0));
        packet.skip(1); // \0 terminated _serverVersion

        _sThread = packet.consume!uint();

        // read first part of scramble buf
        ubyte[] authBuf;
        authBuf.length = 255;
        authBuf[0..8] = packet.consume(8)[]; // scramble_buff

        enforceEx!MYXProtocol(packet.consume!ubyte() == 0, "filler should always be 0");

        consumeServerInfo(packet);

        packet.skip(1); // this byte supposed to be scramble length, but is actually zero
        packet.skip(10); // filler of \0

        // rest of the scramble
        auto len = packet.countUntil(0);
        enforceEx!MYXProtocol(len >= 12, "second part of scramble buffer should be at least 12 bytes");
        enforce(authBuf.length > 8+len);
        authBuf[8..8+len] = packet.consume(len)[];
        authBuf.length = 8+len; // cut to correct size
        enforceEx!MYXProtocol(packet.consume!ubyte() == 0, "Excepted \\0 terminating scramble buf");

        return authBuf;
    }

    static PlainPhobosSocket defaultOpenSocketPhobos(string host, ushort port)
    {
        auto s = new PlainPhobosSocket();
        s.connect(new InternetAddress(host, port));
        return s;
    }

    static PlainVibeDSocket defaultOpenSocketVibeD(string host, ushort port)
    {
        version(Have_vibe_d_core)
            return vibe.core.net.connectTCP(host, port);
        else
            assert(0);
    }

    void initConnection()
    {
        resetPacket();
        final switch(_socketType)
        {
            case MySQLSocketType.phobos:
                _socket = new MySQLSocketPhobos(_openSocketPhobos(_host, _port));
                break;

            case MySQLSocketType.vibed:
                version(Have_vibe_d_core) {
                    _socket = new MySQLSocketVibeD(_openSocketVibeD(_host, _port));
                    break;
                } else assert(0, "Unsupported socket type. Need version Have_vibe_d_core.");
        }
    }

    ubyte[] makeToken(ubyte[] authBuf)
    {
        auto pass1 = sha1Of(cast(const(ubyte)[])_pwd);
        auto pass2 = sha1Of(pass1);

        SHA1 sha1;
        sha1.start();
        sha1.put(authBuf);
        sha1.put(pass2);
        auto result = sha1.finish();
        foreach (size_t i; 0..20)
            result[i] = result[i] ^ pass1[i];
        return result.dup;
    }

    SvrCapFlags getCommonCapabilities(SvrCapFlags server, SvrCapFlags client) pure
    {
        SvrCapFlags common;
        uint filter = 1;
        foreach (size_t i; 0..uint.sizeof)
        {
            bool serverSupport = (server & filter) != 0; // can the server do this capability?
            bool clientSupport = (client & filter) != 0; // can we support it?
            if(serverSupport && clientSupport)
                common |= filter;
            filter <<= 1; // check next flag
        }
        return common;
    }

    void setClientFlags(SvrCapFlags capFlags)
    {
        _cCaps = getCommonCapabilities(_sCaps, capFlags);

        // We cannot operate in <4.1 protocol, so we'll force it even if the user
        // didn't supply it
        _cCaps |= SvrCapFlags.PROTOCOL41;
        _cCaps |= SvrCapFlags.SECURE_CONNECTION;
    }

    void authenticate(ubyte[] greeting)
    in
    {
        assert(_open == OpenState.connected);
    }
    out
    {
        assert(_open == OpenState.authenticated);
    }
    body
    {
        auto token = makeToken(greeting);
        auto authPacket = buildAuthPacket(token);
        send(authPacket);

        auto packet = getPacket();
        auto okp = OKErrorPacket(packet);
        enforceEx!MYX(!okp.error, "Authentication failure: " ~ cast(string) okp.message);
        _open = OpenState.authenticated;
    }

    SvrCapFlags _clientCapabilities;

    void connect(SvrCapFlags clientCapabilities)
    in
    {
        assert(closed);
    }
    out
    {
        assert(_open == OpenState.authenticated);
    }
    body
    {
        initConnection();
        auto greeting = parseGreeting();
        _open = OpenState.connected;

        _clientCapabilities = clientCapabilities;
        setClientFlags(clientCapabilities);
        authenticate(greeting);
    }
    
    // Forcefully close the socket without sending the quit command.
    // Needed in case an error leaves communatations in an undefined or non-recoverable state.
    void kill()
    {
        if(_socket.connected)
            _socket.close();
        _open = OpenState.notConnected;
    }
    
public:

    /**
     * Construct opened connection.
     *
     * After the connection is created, and the initial invitation is received from the server
     * client preferences can be set, and authentication can then be attempted.
     *
     * Parameters:
     *    socketType = Whether to use a Phobos or Vibe.d socket. Default is Phobos,
     *                 unless -version=Have_vibe_d_core is used.
     *    openSocket = Optional callback which should return a newly-opened Phobos
     *                 or Vibe.d TCP socket. This allows custom sockets to be used,
     *                 subclassed from Phobos's or Vibe.d's sockets.
     *    host = An IP address in numeric dotted form, or as a host  name.
     *    user = The user name to authenticate.
     *    password = Users password.
     *    db = Desired initial database.
     *    capFlags = The set of flag bits from the server's capabilities that the client requires
     */
    this(string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
    {
        version(Have_vibe_d_core)
            enum defaultSocketType = MySQLSocketType.vibed;
        else
            enum defaultSocketType = MySQLSocketType.phobos;

        this(defaultSocketType, host, user, pwd, db, port, capFlags);
    }

    ///ditto
    this(MySQLSocketType socketType, string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
    {
        version(Have_vibe_d_core) {} else
            enforceEx!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

        this(socketType, &defaultOpenSocketPhobos, &defaultOpenSocketVibeD,
            host, user, pwd, db, port, capFlags);
    }

    ///ditto
    this(OpenSocketCallbackPhobos openSocket,
        string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
    {
        this(MySQLSocketType.phobos, openSocket, null, host, user, pwd, db, port, capFlags);
    }

    version(Have_vibe_d_core)
    ///ditto
    this(OpenSocketCallbackVibeD openSocket,
        string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
    {
        this(MySQLSocketType.vibed, null, openSocket, host, user, pwd, db, port, capFlags);
    }

    private this(MySQLSocketType socketType,
        OpenSocketCallbackPhobos openSocketPhobos, OpenSocketCallbackVibeD openSocketVibeD,
        string host, string user, string pwd, string db, ushort port = 3306, SvrCapFlags capFlags = defaultClientFlags)
    in
    {
        final switch(socketType)
        {
            case MySQLSocketType.phobos: assert(openSocketPhobos !is null); break;
            case MySQLSocketType.vibed:  assert(openSocketVibeD  !is null); break;
        }
    }
    body
    {
        enforceEx!MYX(capFlags & SvrCapFlags.PROTOCOL41, "This client only supports protocol v4.1");
        enforceEx!MYX(capFlags & SvrCapFlags.SECURE_CONNECTION, "This client only supports protocol v4.1 connection");
        version(Have_vibe_d_core) {} else
            enforceEx!MYX(socketType != MySQLSocketType.vibed, "Cannot use Vibe.d sockets without -version=Have_vibe_d_core");

        _socketType = socketType;
        _host = host;
        _user = user;
        _pwd = pwd;
        _db = db;
        _port = port;

        _openSocketPhobos = openSocketPhobos;
        _openSocketVibeD  = openSocketVibeD;

        connect(capFlags);
    }

    /**
     * Construct opened connection.
     *
     * After the connection is created, and the initial invitation is received from
     * the server client preferences are set, and authentication can then be attempted.
     *
     * TBD The connection string needs work to allow for semicolons in its parts!
     *
     * Parameters:
     *    socketType = Whether to use a Phobos or Vibe.d socket. Default is Phobos
     *                 unless -version=Have_vibe_d_core is used.
     *    openSocket = Optional callback which should return a newly-opened Phobos
     *                 or Vibe.d TCP socket. This allows custom sockets to be used,
     *                 subclassed from Phobos's or Vibe.d's sockets.
     *    cs = A connection string of the form "host=localhost;user=user;pwd=password;db=mysqld"
     *    capFlags = The set of flag bits from the server's capabilities that the client requires
     */
    this(string cs, SvrCapFlags capFlags = defaultClientFlags)
    {
        string[] a = parseConnectionString(cs);
        this(a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
    }

    ///ditto
    this(MySQLSocketType socketType, string cs, SvrCapFlags capFlags = defaultClientFlags)
    {
        string[] a = parseConnectionString(cs);
        this(socketType, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
    }

    ///ditto
    this(OpenSocketCallbackPhobos openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
    {
        string[] a = parseConnectionString(cs);
        this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
    }

    version(Have_vibe_d_core)
    ///ditto
    this(OpenSocketCallbackVibeD openSocket, string cs, SvrCapFlags capFlags = defaultClientFlags)
    {
        string[] a = parseConnectionString(cs);
        this(openSocket, a[0], a[1], a[2], a[3], to!ushort(a[4]), capFlags);
    }

    @property bool closed()
    {
        return _open == OpenState.notConnected || !_socket.connected;
    }

    version(Have_vibe_d_core)
    {
        void acquire() { if( _socket ) _socket.acquire(); }
        void release() { if( _socket ) _socket.release(); }
        bool isOwner() { return _socket ? _socket.isOwner() : false; }
        bool amOwner() { return _socket ? _socket.isOwner() : false; }
    }
    else
    {
        void acquire() { /+ Do nothing +/ }
        void release() { /+ Do nothing +/ }
        bool isOwner() { return !!_socket; }
        bool amOwner() { return !!_socket; }
    }

    /**
     * Explicitly close the connection.
     *
     * This is a two-stage process. First tell the server we are quitting this
     * connection, and then close the socket.
     *
     * Idiomatic use as follows is suggested:
     * ------------------
     * {
     *     auto con = Connection("localhost:user:password:mysqld");
     *     scope(exit) con.close();
     *     // Use the connection
     *     ...
     * }
     * ------------------
     */
    void close()
    {
        if (_open == OpenState.authenticated && _socket.connected)
            quit();

        if (_open == OpenState.connected)
            kill();
        resetPacket();
    }

    void reconnect()
    {
        reconnect(_clientCapabilities);
    }

    void reconnect(SvrCapFlags clientCapabilities)
    {
        bool sameCaps = clientCapabilities == _clientCapabilities;
        if(!closed)
        {
            // Same caps as before?
            if(clientCapabilities == _clientCapabilities)
                return; // Nothing to do, just keep current connection

            close();
        }

        connect(clientCapabilities);
    }

    private void quit()
    in
    {
        assert(_open == OpenState.authenticated);
    }
    body
    {
        sendCmd(CommandType.QUIT, []);
        // No response is sent for a quit packet
        _open = OpenState.connected;
    }

    static string[] parseConnectionString(string cs)
    {
        string[] rv;
        rv.length = 5;
        rv[4] = "3306"; // Default port
        string[] a = split(cs, ";");
        foreach (s; a)
        {
            string[] a2 = split(s, "=");
            enforceEx!MYX(a2.length == 2, "Bad connection string: " ~ cs);
            string name = strip(a2[0]);
            string val = strip(a2[1]);
            switch (name)
            {
                case "host":
                    rv[0] = val;
                    break;
                case "user":
                    rv[1] = val;
                    break;
                case "pwd":
                    rv[2] = val;
                    break;
                case "db":
                    rv[3] = val;
                    break;
                case "port":
                    rv[4] = val;
                    break;
                default:
                    throw new MYX("Bad connection string: " ~ cs, __FILE__, __LINE__);
            }
        }
        return rv;
    }

    /**
     * Select a current database.
     *
     * Params: dbName = Name of the requested database
     * Throws: MySQLException
     */
    void selectDB(string dbName)
    {
        sendCmd(CommandType.INIT_DB, dbName);
        getCmdResponse();
        _db = dbName;
    }

    /**
     * Check the server status
     *
     * Returns: An OKErrorPacket from which server status can be determined
     * Throws: MySQLException
     */
    OKErrorPacket pingServer()
    {
        sendCmd(CommandType.PING, []);
        return getCmdResponse();
    }

    /**
     * Refresh some feature(s) of the server.
     *
     * Returns: An OKErrorPacket from which server status can be determined
     * Throws: MySQLException
     */
    OKErrorPacket refreshServer(RefreshFlags flags)
    {
        sendCmd(CommandType.REFRESH, [flags]);
        return getCmdResponse();
    }

    /**
     * Get a textual report on the server status.
     *
     * (COM_STATISTICS)
     */
    string serverStats()
    {
        sendCmd(CommandType.STATISTICS, []);
        return cast(string) getPacket();
    }

    /**
     * Enable multiple statement commands
     *
     * This can be used later if this feature was not requested in the client capability flags.
     *
     * Params: on = Boolean value to turn the capability on or off.
     */
    void enableMultiStatements(bool on)
    {
        scope(failure) kill();

        ubyte[] t;
        t.length = 2;
        t[0] = on ? 0 : 1;
        t[1] = 0;
        sendCmd(CommandType.STMT_OPTION, cast(string) t);

        // For some reason this command gets an EOF packet as response
        auto packet = getPacket();
        enforceEx!MYXProtocol(packet[0] == 254 && packet.length == 5, "Unexpected response to SET_OPTION command");
    }

    /// Return the in-force protocol number
    @property ubyte protocol() pure const nothrow { return _protocol; }
    /// Server version
    @property string serverVersion() pure const nothrow { return _serverVersion; }
    /// Server capability flags
    @property uint serverCapabilities() pure const nothrow { return _sCaps; }
    /// Server status
    @property ushort serverStatus() pure const nothrow { return _serverStatus; }
    /// Current character set
    @property ubyte charSet() pure const nothrow { return _sCharSet; }
    /// Current database
    @property string currentDB() pure const nothrow { return _db; }
    /// Socket type being used
    @property MySQLSocketType socketType() pure const nothrow { return _socketType; }
}
