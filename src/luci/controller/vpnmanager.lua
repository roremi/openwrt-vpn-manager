module("luci.controller.vpnmanager", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/vpn-manager") then
        return
    end

    entry({"admin", "services", "vpnmanager"}, call("dashboard"), _("VPN Manager"), 60).dependent = true
    entry({"admin", "services", "vpnmanager", "profiles"}, call("rpc_profiles")).leaf = true
    entry({"admin", "services", "vpnmanager", "devices"}, call("rpc_devices")).leaf = true
    entry({"admin", "services", "vpnmanager", "policies"}, call("rpc_policies")).leaf = true
    entry({"admin", "services", "vpnmanager", "status"}, call("rpc_status")).leaf = true
    entry({"admin", "services", "vpnmanager", "audit"}, call("rpc_audit")).leaf = true
    entry({"admin", "services", "vpnmanager", "toggle"}, call("rpc_toggle")).leaf = true
    entry({"admin", "services", "vpnmanager", "policy"}, call("rpc_policy")).leaf = true
    entry({"admin", "services", "vpnmanager", "policy_delete"}, call("rpc_policy_delete")).leaf = true
    entry({"admin", "services", "vpnmanager", "profile"}, call("rpc_profile")).leaf = true
    entry({"admin", "services", "vpnmanager", "profile_delete"}, call("rpc_profile_delete")).leaf = true
    entry({"admin", "services", "vpnmanager", "test"}, call("rpc_test")).leaf = true
    entry({"admin", "services", "vpnmanager", "import"}, call("rpc_import")).leaf = true
    entry({"admin", "services", "vpnmanager", "multiebay_settings"}, call("rpc_multiebay_settings")).leaf = true
    entry({"admin", "services", "vpnmanager", "multiebay_settings_save"}, call("rpc_multiebay_settings_save")).leaf = true
    entry({"admin", "services", "vpnmanager", "multiebay_settings_clear"}, call("rpc_multiebay_settings_clear")).leaf = true
    entry({"admin", "services", "vpnmanager", "multiebay_import"}, call("rpc_multiebay_import")).leaf = true
    entry({"admin", "services", "vpnmanager", "apply"}, call("rpc_apply")).leaf = true
    entry({"admin", "services", "vpnmanager", "rollback"}, call("rpc_rollback")).leaf = true
end

function dashboard()
    local html = nixio.fs.readfile("/www/vpnmanager-dashboard.html")
    if not html then
        luci.http.status(404, "Not Found")
        luci.http.prepare_content("text/plain")
        luci.http.write("vpnmanager dashboard not installed")
        return
    end

    luci.http.prepare_content("text/html")
    luci.http.write(html)
end

local function run_rpc(method)
    local out = luci.sys.exec("/usr/libexec/rpcd/vpn-manager " .. method)
    luci.http.prepare_content("application/json")
    luci.http.write(out)
end

local function sq(v)
    return luci.util.shellquote(v or "")
end

function rpc_profiles()
    run_rpc("list_profiles")
end

function rpc_devices()
    run_rpc("list_devices")
end

function rpc_policies()
    run_rpc("list_policies")
end

function rpc_status()
    run_rpc("status")
end

function rpc_audit()
    run_rpc("audit_log")
end

function rpc_toggle()
    local id = luci.http.formvalue("id") or ""
    local enabled = luci.http.formvalue("enabled") or "1"
    run_rpc("toggle_profile " .. sq(id) .. " " .. sq(enabled))
end

function rpc_policy()
    local section = luci.http.formvalue("section") or ""
    local mac = luci.http.formvalue("mac") or ""
    local ip = luci.http.formvalue("ip") or ""
    local hostname = luci.http.formvalue("hostname") or ""
    local target = luci.http.formvalue("target") or "wan"
    run_rpc("set_policy " .. sq(section) .. " " .. sq(mac) .. " " .. sq(ip) .. " " .. sq(hostname) .. " " .. sq(target))
end

function rpc_policy_delete()
    local section = luci.http.formvalue("section") or ""
    run_rpc("delete_policy " .. sq(section))
end

function rpc_profile()
    local id = luci.http.formvalue("id") or ""
    local name = luci.http.formvalue("name") or ""
    local endpoint_host = luci.http.formvalue("endpoint_host") or ""
    local endpoint_port = luci.http.formvalue("endpoint_port") or ""
    local public_key = luci.http.formvalue("public_key") or ""
    local private_key = luci.http.formvalue("private_key") or ""
    local address = luci.http.formvalue("address") or ""
    local dns = luci.http.formvalue("dns") or ""
    local allowed_ips = luci.http.formvalue("allowed_ips") or ""
    local mtu = luci.http.formvalue("mtu") or ""
    local keepalive = luci.http.formvalue("persistent_keepalive") or ""
    local enabled = luci.http.formvalue("enabled") or "1"
    local preshared_key = luci.http.formvalue("preshared_key") or ""

    run_rpc(
        "set_profile " ..
        sq(id) .. " " ..
        sq(name) .. " " ..
        sq(endpoint_host) .. " " ..
        sq(endpoint_port) .. " " ..
        sq(public_key) .. " " ..
        sq(private_key) .. " " ..
        sq(address) .. " " ..
        sq(dns) .. " " ..
        sq(allowed_ips) .. " " ..
        sq(mtu) .. " " ..
        sq(keepalive) .. " " ..
        sq(enabled) .. " " ..
        sq(preshared_key)
    )
end

function rpc_profile_delete()
    local id = luci.http.formvalue("id") or ""
    run_rpc("delete_profile " .. sq(id))
end

function rpc_test()
    local id = luci.http.formvalue("id") or ""
    run_rpc("test_profile " .. sq(id))
end

function rpc_import()
    local id = luci.http.formvalue("id") or ""
    local path = luci.http.formvalue("path") or ""
    local content = luci.http.formvalue("content") or ""

    if content ~= "" then
        local tmp = "/tmp/vpnmanager-import-" .. tostring(os.time()) .. ".conf"
        local fh = nixio.open(tmp, "w", 420)
        if not fh then
            luci.http.status(500, "Internal Server Error")
            luci.http.prepare_content("application/json")
            luci.http.write('{"ok":false,"error":"unable to write temp file"}')
            return
        end

        fh:write(content)
        fh:close()
        path = tmp
    end

    run_rpc("import_profile " .. sq(id) .. " " .. sq(path))
end

function rpc_multiebay_import()
    local id = luci.http.formvalue("id") or ""
    local api_base = luci.http.formvalue("api_base") or "https://multiebay.com"
    local api_key = luci.http.formvalue("api_key") or ""
    local proxy_url = luci.http.formvalue("proxy_url") or ""
    local gateway_name = luci.http.formvalue("gateway_name") or ""
    local client_name = luci.http.formvalue("client_name") or ""
    local profile_name = luci.http.formvalue("profile_name") or ""
    local allow_http_proxy = luci.http.formvalue("allow_http_proxy") or "1"

    run_rpc(
        "create_multiebay_profile " ..
        sq(id) .. " " ..
        sq(api_base) .. " " ..
        sq(api_key) .. " " ..
        sq(proxy_url) .. " " ..
        sq(gateway_name) .. " " ..
        sq(client_name) .. " " ..
        sq(profile_name) .. " " ..
        sq(allow_http_proxy)
    )
end

function rpc_multiebay_settings()
    run_rpc("list_multiebay_settings")
end

function rpc_multiebay_settings_save()
    local api_base = luci.http.formvalue("api_base") or "https://multiebay.com"
    local api_key = luci.http.formvalue("api_key") or ""
    local allow_http_proxy = luci.http.formvalue("allow_http_proxy") or "1"

    run_rpc(
        "save_multiebay_settings " ..
        sq(api_base) .. " " ..
        sq(api_key) .. " " ..
        sq(allow_http_proxy)
    )
end

function rpc_multiebay_settings_clear()
    run_rpc("clear_multiebay_api_key")
end

function rpc_apply()
    run_rpc("apply")
end

function rpc_rollback()
    run_rpc("rollback")
end
