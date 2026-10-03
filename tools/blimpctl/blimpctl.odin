package blimpctl

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

// Sends one command to a running Blimp editor (debug build) and prints the reply. See src/editor_remote.odin.
//   blimpctl help
//   blimpctl entities castle.level
//   blimpctl set castle.level 吊桥 position "0, 0, -3.15"
//   blimpctl paste castle.level - < blocks.txt      ('-' sends stdin as the request body)
// Exit code: 0 ok, 1 the engine reported an error, 2 couldn't reach the engine / bad usage.
PORT :: 47800   // must match REMOTE_PORT in src/editor_remote.odin

main :: proc() {
    args := utf8_args()[1:]
    if len(args) == 0 {
        fmt.eprintln("usage: blimpctl <command> [args...]   (blimpctl help lists commands)")
        os.exit(2)
    }

    body: []u8
    if args[len(args) - 1] == "-" {
        args = args[:len(args) - 1]
        data, err := os.read_entire_file_from_file(os.stdin, context.allocator)
        if err != nil { fmt.eprintln("blimpctl: can't read stdin:", err); os.exit(2) }
        body = data
    }

    // Re-quote arguments the shell already split, so the engine's tokenizer sees the same words.
    line := strings.builder_make()
    for a, i in args {
        if i > 0 do strings.write_byte(&line, ' ')
        if a == "" || strings.contains_any(a, " \t") do fmt.sbprintf(&line, "\"%s\"", a)
        else do strings.write_string(&line, a)
    }
    strings.write_byte(&line, '\n')

    sock, err := net.dial_tcp_from_hostname_and_port_string(fmt.tprintf("127.0.0.1:%d", PORT))
    if err != nil {
        fmt.eprintfln("blimpctl: can't reach the engine on 127.0.0.1:%d — is a debug build running? (%v)", PORT, err)
        os.exit(2)
    }
    send_all(sock, line.buf[:])
    send_all(sock, body)
    net.shutdown(sock, .Send)   // end of request

    reply := make([dynamic]u8)
    chunk: [16 * 1024]u8
    for {
        n, rerr := net.recv_tcp(sock, chunk[:])
        if rerr != nil || n == 0 do break
        append(&reply, ..chunk[:n])
    }
    net.close(sock)

    status, _, text := strings.partition(string(reply[:]), "\n")
    switch status {
    case "ok":
        fmt.print(text)
    case "error":
        fmt.eprint(text)
        os.exit(1)
    case:
        fmt.eprintln("blimpctl: no reply (did the engine close?)")
        os.exit(2)
    }
}

// The arguments as UTF-8. Not os.args: on Windows Odin fills that from the C runtime's ANSI argv, which
// turns anything outside the code page (every Chinese entity name) into '?'. The UTF-16 command line has them.
utf8_args :: proc() -> []string {
    argc: i32
    argv := win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc)
    defer win32.LocalFree(argv)
    args := make([]string, argc)
    for i in 0 ..< int(argc) do args[i], _ = win32.wstring_to_utf8(argv[i], -1, context.allocator)
    return args
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) {
    for sent := 0; sent < len(data); {
        n, err := net.send_tcp(sock, data[sent:])
        if err != nil { fmt.eprintln("blimpctl: send failed:", err); os.exit(2) }
        sent += n
    }
}
