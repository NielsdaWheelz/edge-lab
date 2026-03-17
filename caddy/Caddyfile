{
	admin 0.0.0.0:2019
}

preview-abc.codapt.local {
	tls internal
	reverse_proxy frps:8080
}

*.codapt.local {
	tls internal
	respond "route not found" 404
}
