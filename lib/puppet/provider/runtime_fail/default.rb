Puppet::Type.type(:runtime_fail).provide(
  :default,
) do

  def ready
    if resource[:fail]
      fail(resource[:message])
    end
  end

  def ready=(val)
    # do nothing
  end

end
