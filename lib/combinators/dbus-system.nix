{
  combinators,
  helpers,
  jail,
  lib,
  pkgs,
  ...
}:
let
  inherit (combinators)
    add-cleanup
    add-runtime
    compose
    defer
    include-once
    noescape
    readwrite
    rw-bind
    unsafe-dbus
    ;
in
{
  sig = "{ own? :: [String], talk? :: [String], see? :: [String], call? :: [String], broadcast? :: [String] } -> Permission";
  doc = ''
    Grants access to dbus, using
    [`xdg-dbus-proxy`](https://github.com/flatpak/xdg-dbus-proxy) (inside a
    jail itself) to filter messages that can be sent/received.

    Same as `dbus` combinator, but exposes system dbus socket in sandbox.

    All of the args in the passed attrset turn into arguments for
    `xdg-dbus-proxy`. They are all optional.

    Example:
    ```
    dbus-system {
      talk = [
        "org.bluez"
        "org.freedesktop.Avahi"
        "org.freedesktop.UPower"
      ];
    }
    ```
  '';
  impl =
    {
      own ? [ ],
      talk ? [ ],
      see ? [ ],
      call ? [ ],
      broadcast ? [ ],
    }:
    compose [
      # Just set the options on state so dbus can be called multiple times
      (helpers.pushState "dbusSystemPermissions" {
        inherit
          own
          talk
          see
          call
          broadcast
          ;
      })
      # Then add deferred runtime logic to spin up xdg-dbus-proxy:
      (include-once "dbus-system" (
        defer (
          state:
          let
            proxy = jail "xdg-dbus-proxy-system" pkgs.xdg-dbus-proxy [
              unsafe-dbus
              (readwrite (noescape "\"$PROXIED_SYSTEM_DBUS_SOCKET_DIR\""))
              (readwrite "/run/dbus/system_bus_socket")
            ];

            getFlags =
              type:
              lib.pipe state.dbusSystemPermissions [
                (map (p: p.${type}))
                lib.flatten
                lib.unique
                (map (id: "--${type}=${lib.escapeShellArg id}"))
              ];

            args = [
              "--filter"
            ]
            ++ getFlags "own"
            ++ getFlags "talk"
            ++ getFlags "see"
            ++ getFlags "call"
            ++ getFlags "broadcast";
          in
          compose [
            (add-runtime ''
              PROXIED_SYSTEM_DBUS_SOCKET_DIR=$(mktemp -d)
              export PROXIED_SYSTEM_DBUS_SOCKET_DIR
              PROXIED_SYSTEM_DBUS_SOCKET="$PROXIED_SYSTEM_DBUS_SOCKET_DIR/socket"
              mkfifo "$PROXIED_SYSTEM_DBUS_SOCKET_DIR/ready"
              exec {XDG_SYSTEM_DBUS_PROXY_READY_FD}<>"$PROXIED_SYSTEM_DBUS_SOCKET_DIR/ready"
              ${lib.getExe proxy} \
                "unix:path=/run/dbus/system_bus_socket" \
                "$PROXIED_SYSTEM_DBUS_SOCKET" \
                --fd="$XDG_SYSTEM_DBUS_PROXY_READY_FD" \
                ${lib.concatStringsSep " " args} \
                &
              SYSTEM_PROXY_PID=$!
              IFS= read -rn1 -u "$XDG_SYSTEM_DBUS_PROXY_READY_FD"
            '')
            (add-cleanup ''
              kill "$SYSTEM_PROXY_PID"
              if [ -e "''${PROXIED_SYSTEM_DBUS_SOCKET_DIR-}" ]; then
                rm -rf "$PROXIED_SYSTEM_DBUS_SOCKET_DIR"
              fi
            '')
            (rw-bind (noescape "\"$PROXIED_SYSTEM_DBUS_SOCKET\"") "/run/dbus/system_bus_socket")
          ] state
        )
      ))
    ];
}
