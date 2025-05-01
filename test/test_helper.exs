{_, 0} = System.cmd("epmd", ["-daemon"])
Node.start(:enfiladex, :shortnames)
ExUnit.start()
