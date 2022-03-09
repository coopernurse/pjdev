output "lb_ip_addr" {
  value = google_compute_global_address.default.address
}
