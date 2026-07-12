# OpenTofu config for `philip9.com` DNS Zone on Cloudflare
#
# This DNS zone is just for typo/namesquat prevention on `phlip9.com`.
#
# TODO(phlip9): actually setup redirect
{ config, ... }:

let
  zone_id = config.data.cloudflare_zone.philip9_com "id";
in

{
  # DNS Zone data source
  data.cloudflare_zone = {
    philip9_com.filter.name = "philip9.com";
  };

  # DNS records
  resource.cloudflare_dns_record = {
    # github pages IPs at the apex
    a_github_pages_108_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "A";
      content = "185.199.108.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_109_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "A";
      content = "185.199.109.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_110_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "A";
      content = "185.199.110.153";
      ttl = 1; # automatic
      proxied = false;
    };
    a_github_pages_111_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "A";
      content = "185.199.111.153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_0_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "AAAA";
      content = "2606:50c0:8000::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_1_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "AAAA";
      content = "2606:50c0:8001::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_2_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "AAAA";
      content = "2606:50c0:8002::153";
      ttl = 1; # automatic
      proxied = false;
    };
    aaaa_github_pages_3_philip9_com = {
      inherit zone_id;
      name = "philip9.com";
      type = "AAAA";
      content = "2606:50c0:8003::153";
      ttl = 1; # automatic
      proxied = false;
    };

    # github pages CNAME for www.philip9.com subdomain
    cname_www_philip9_com = {
      inherit zone_id;
      name = "www.philip9.com";
      type = "CNAME";
      content = "phlip9.com";
      ttl = 1; # automatic
      proxied = false;
      settings.flatten_cname = false;
    };
  };
}
