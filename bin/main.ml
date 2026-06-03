let () =
  let session = Topup.Session.create () in
  Mcp.Server.run ~ic:stdin ~oc:stdout ~session
