# IP-facing management API (default_server on HTTP).
# Clients call http://<vm-public-ip>/api/game/url-extended/<client> with Basic Auth
# (shared username/password for all clients). HTTPS is not used here because a
# publicly trusted certificate cannot be issued for a raw IP.

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        return 404 '{"status":"NOT_FOUND"}';
        default_type application/json;
    }

    # Require client suffix: /api/game/url-extended/<client>
    location = /api/game/url-extended {
        auth_basic           "proxies domain API";
        auth_basic_user_file __API_HTPASSWD__;
        default_type application/json;
        add_header Cache-Control "no-store" always;
        return 404 '{"status":"NOT_FOUND","message":"Use /api/game/url-extended/<client>"}';
    }

    location ~ ^/api/game/url-extended/([A-Za-z0-9][A-Za-z0-9_-]*)$ {
        auth_basic           "proxies domain API";
        auth_basic_user_file __API_HTPASSWD__;

        set $api_client $1;

        # Static files reject POST with 405. Named error_page locations keep POST,
        # so they 405 again. URI-based error_page switches the method to GET.
        # Game clients (Apache-HttpClient) POST; body is ignored.
        error_page 418 = /__proxies_urls/$api_client.json;
        return 418;
    }

    location /__proxies_urls/ {
        internal;

        # The auth_basic on the location above never runs: 'return 418' is handled
        # in the rewrite phase, which precedes the access phase where auth_basic
        # is evaluated. The error_page then redirects internally to here, and
        # without a check of its own this location served the payload to anyone -
        # no credentials and a wrong password both returned 200. Repeating the
        # check here puts it in the access phase of the redirected request, which
        # does run. Keep both: the one above issues the challenge for a plain GET.
        auth_basic           "proxies domain API";
        auth_basic_user_file __API_HTPASSWD__;

        default_type application/json;
        add_header Cache-Control "no-store" always;
        alias __URLS_ROOT__/urls/;
    }
}

# Catch HTTPS to the raw IP so it does not fall through to a domain vhost.
# No certificate is required; the handshake is rejected.
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
