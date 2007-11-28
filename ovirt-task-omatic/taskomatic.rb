#!/usr/bin/ruby

$: << "../wui/src/app"

require 'active_record'
require 'erb'
require 'libvirt'
require 'rexml/document'
include REXML

require 'models/task.rb'
require 'models/host.rb'
require 'models/vm.rb'
require 'models/storage_volume.rb'

def database_configuration
  YAML::load(ERB.new(IO.read('../wui/src/config/database.yml')).result)
end

def create_vm_xml(name, uuid, memAllocated, memUsed, vcpus, macAddr, bridge,
                  disk_device)
  doc = Document.new

  doc.add_element("domain", {"type" => "kvm"})
  
  doc.root.add_element("name")
  doc.root.elements["name"].text = name
  
  doc.root.add_element("uuid")
  doc.root.elements["uuid"].text = uuid
  
  doc.root.add_element("memory")
  doc.root.elements["memory"].text = memAllocated
  
  doc.root.add_element("currentMemory")
  doc.root.elements["currentMemory"].text = memUsed
  
  doc.root.add_element("vcpu")
  doc.root.elements["vcpu"].text = vcpus
  
  doc.root.add_element("os")
  doc.root.elements["os"].add_element("type")
  doc.root.elements["os"].elements["type"].text = "hvm"
  doc.root.elements["os"].add_element("boot", {"dev" => "network"})
  
  doc.root.add_element("clock", {"offset" => "utc"})
  
  doc.root.add_element("on_poweroff")
  doc.root.elements["on_poweroff"].text = "destroy"
  
  doc.root.add_element("on_reboot")
  doc.root.elements["on_reboot"].text = "restart"
  
  doc.root.add_element("on_crash")
  doc.root.elements["on_crash"].text = "destroy"
  
  doc.root.add_element("devices")
  doc.root.elements["devices"].add_element("emulator")
  doc.root.elements["devices"].elements["emulator"].text = "/usr/bin/qemu-kvm"
  doc.root.elements["devices"].add_element("disk", {"type" => "block", "device" => "disk"})
  doc.root.elements["devices"].elements["disk"].add_element("source", {"dev" => disk_device})
  doc.root.elements["devices"].elements["disk"].add_element("target", {"dev" => "hda"})
  doc.root.elements["devices"].add_element("interface", {"type" => "bridge"})
  doc.root.elements["devices"].elements["interface"].add_element("mac", {"address" => macAddr})
  doc.root.elements["devices"].elements["interface"].add_element("source", {"bridge" => bridge})
  doc.root.elements["devices"].elements["interface"].add_element("target", {"dev" => "vnet0"})
  doc.root.elements["devices"].add_element("input", {"type" => "mouse", "bus" => "ps2"})
  doc.root.elements["devices"].add_element("graphics", {"type" => "vnc", "port" => "-1", "listen" => "0.0.0.0"})

  return doc
end

def setTaskState(task, state, msg = nil)
  task.state = state
  #task.msg = msg
  task.save
end

def findVM(task, fail_on_nil_host_id = true)
  # first, find the matching VM in the vms table
  vm = Vm.find(:first, :conditions => [ "id = ?", task.vm_id ])
  
  if vm == nil
    puts "No VM found"
    setTaskState(task, Task::STATE_FAILED, "VM id " + task.vm_id + "not found")
    raise
  end

  if vm.host_id == nil && fail_on_nil_host_id
    # in this case, we have no idea where the VM is.  How can we handle this
    # gracefully?  We don't necessarily want to just set the VM state to off;
    # if the machine does happen to be running somewhere and we set it to
    # disabled here, and then start it again, we could corrupt the disk

    # FIXME: the right thing to do here is probably to contact all of the
    # hosts we know about and ensure that the domain isn't running; then we
    # can mark it either as off (if we didn't find it), or mark the correct
    # vm.host_id if we did.  However, if you have a large number of hosts
    # out there, this could take a while.
    setTaskState(task, Task::STATE_FAILED, "No host_id for VM" + task.vm_id)
    raise
  end

  return vm
end

def findHost(task, vm)
  host = Host.find(:first, :conditions => [ "id = ?", vm.host_id])

  if host == nil
    # Hm, we didn't find the host_id.  Seems odd.  Return a failure

    # FIXME: we should probably contact the hosts we know about and check to
    # see if this VM is running
    setTaskState(task, Task::STATE_FAILED, "Could not find the host that VM is running on")
    raise
  end

  return host
end

# a function to find a SCSI wwid based on ipaddr, port, target, lun.  Note
# that this runs locally, so the management server will have to have access
# to the same iSCSI LUNs as the guests will
def find_wwid(ipaddr, port, target, lun)
  system('/sbin/iscsiadm --mode discovery --type sendtargets --portal $IPADDR >& /dev/null')
  system('/sbin/iscsiadm --mode node --targetname $TARGET --portal $IPADDR:$PORT --login >& /dev/null')
  
  sessions = Dir['/sys/class/iscsi_session/session*']

  sessions.each do |session|
    current = IO.read(session + '/targetname')
    if not target <=> current
      next
    end

    # OK, we found the target; now let's go looking for the devices
    devices = Dir[session + '/device/target*/[0-9]*:' + lun.to_s]

    devices.each do |device|
      blocks = Dir[device + '/block:sd*']
      blocks.each do |block|
        out = IO.popen('/sbin/scsi_id -g -u -s ' + block.sub(/\/sys(.*)/, '\1'), mode="r")
        id = out.readline
        out.close
        return id.chomp
      end
    end
  end
  return nil
end

$dbconfig = database_configuration
$develdb = $dbconfig['development']
ActiveRecord::Base.establish_connection(
                                        :adapter  => $develdb['adapter'],
                                        :host     => $develdb['host'],
                                        :username => $develdb['username'],
                                        :password => $develdb['password'],
                                        :database => $develdb['database']
                                        )

def create_vm(task)
  puts "create_vm"

  # since we are actually generating XML on the fly in the "start_vm" method,
  # we don't actually need to do much here.  We might need to allocate disk
  # space, etc, but we can skip that for now

  # FIXME: what do we do about attaching a CDROM for first install?

  setTaskState(task, Task::STATE_FINISHED)
end

def shutdown_vm(task)
  puts "shutdown_vm"

  # here, we are given an id for a VM to shutdown; we have to lookup which
  # physical host it is running on

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_STOPPED
    # the VM is already shutdown; just return success
    setTaskState(task, Task::STATE_FINISHED)
    vm.host_id = nil
    vm.save
    return
  elsif vm.state == Vm::STATE_PAUSED || vm.state == Vm::STATE_SAVED
    # FIXME: hm, we have two options here: either resume the VM and then
    # shut it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown paused domain")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table
  begin
    host = findHost(task, vm)
  rescue
    return
  end

  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.lookupDomainByUUID(vm.uuid)
    dom.shutdown
    dom.undefine
    conn.close
  rescue
    setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
    return
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.host_id = nil
  vm.state = Vm::STATE_STOPPED
  vm.save
end

def start_vm(task)
  puts "start_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task, false)
  rescue
    return
  end

  if vm.state == Vm::STATE_RUNNING
    # the VM is already running; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_PAUSED || vm.state == Vm::STATE_SAVED
    # FIXME: hm, we have two options here: either resume the VM and then
    # shut it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown paused domain")
    return
  end

  # the VM might be in an inconsistent state in the database; however, we
  # should check it out on the remote host, and update the database as
  # appropriate

  if vm.host_id != nil
    # OK, marked in the database as already running on a host; for now, we
    # will just fail the operation

    # FIXME: we probably want to go out to the host it is marked on and check
    # things out, just to make sure things are consistent

    setTaskState(task, Task::STATE_FAILED, "VM already running")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table to see if there
  # is a host that will fit these constraints
  host = Host.find(:first, :conditions => [ "num_cpus >= ? AND memory >= ?",
                                            vm.num_vcpus_allocated,
                                            vm.memory_allocated])

  if host == nil
    # we couldn't find a host that matches this description; report ERROR
    setTaskState(task, Task::STATE_FAILED, "No host matching VM parameters could be found")
    return
  end

  vm.storage_volumes.each do |volume|
    $wwid = find_wwid(volume.ip_addr, volume.port, volume.target, volume.lun)
    # FIXME: right now we are only looking at the very first volume; eventually
    # we will want to do every volume here
    break
  end

  # OK, we found a host that will work; now let's build up the XML

  # FIXME: get rid of the hardcoded bridge and disk here
  xml = create_vm_xml(vm.description, vm.uuid, vm.memory_allocated,
                      vm.memory_used, vm.num_vcpus_used, vm.vnic_mac_addr,
                      "ovirtbr0",
                      "/dev/disk/by-id/scsi-" + $wwid)

  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.defineDomainXML(xml.to_s)
    dom.create
    conn.close
  rescue
    # FIXME: these may fail for various reasons:
    # 1.  The domain is already defined and/or started - update the DB
    # 2.  We couldn't define the domain for some reason
    setTaskState(task, Task::STATE_FAILED, "Libvirt error")
    return
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.host_id = host.id
  vm.state = Vm::STATE_RUNNING
  vm.save
end

def save_vm(task)
  puts "save_vm"

  # here, we are given an id for a VM to suspend

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_SAVED
    # the VM is already saved; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_PAUSED
    # FIXME: hm, we have two options here: either resume the VM and then
    # save it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot save paused domain")
    return    
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot save shutdown domain")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table
  begin
    host = findHost(task, vm)
  rescue
    return
  end

  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.lookupDomainByUUID(vm.uuid)
    dom.save("/tmp/" + vm.uuid + ".save")
    conn.close
  rescue
    setTaskState(task, Task::STATE_FAILED, "Save failed")
    return
  end

  # note that we do *not* reset the host_id here, since we stored the saved
  # vm state information locally.  restore_vm will pick it up from here

  # FIXME: it would be much nicer to be able to save the VM and remove the
  # the host_id and undefine the XML; that way we could resume it on another
  # host later.  This needs more thought

  vm.state = Vm::STATE_SAVED
  setTaskState(task, Task::STATE_FINISHED)

  vm.save
end

def restore_vm(task)
  puts "restore_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_RUNNING
    # the VM is already saved; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_PAUSED
    # FIXME: hm, we have two options here: either resume the VM and then
    # save it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot restore paused domain")
    return    
  elsif vm.state == Vm::STATE_STOPPED
    setTaskState(task, Task::STATE_FAILED, "Cannot restore shutdown domain")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table
  begin
    host = findHost(task, vm)
  rescue
    return
  end

  # FIXME: we should probably go out to the host and check what it thinks
  # the state is
  
  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.lookupDomainByUUID(vm.uuid)
    dom.restore
    conn.close
  rescue
    # FIXME: these may fail for various reasons:
    # 1.  The domain is already defined and/or started - update the DB
    # 2.  We couldn't define the domain for some reason
    setTaskState(task, Task::STATE_FAILED, "Libvirt error")
    return
  end

  setTaskState(task, Task::STATE_FINISHED)

  vm.state = Vm::STATE_RUNNING
  vm.save
end

def suspend_vm(task)
  puts "suspend_vm"

  # here, we are given an id for a VM to suspend; we have to lookup which
  # physical host it is running on

  begin
    vm = findVM(task)
  rescue
    return
  end

  if vm.state == Vm::STATE_PAUSED
    # the VM is already paused; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_STOPPED || vm.state == Vm::STATE_SAVED
    # FIXME: hm, we have two options here: either resume the VM and then
    # pause it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown paused domain")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table
  begin
    host = findHost(task, vm)
  rescue
    return
  end

  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.lookupDomainByUUID(vm.uuid)
    dom.suspend
    conn.close
  rescue
    setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
    return
  end

  # note that we do *not* reset the host_id here, since we just paused the VM
  # resume_vm will pick it up from here

  setTaskState(task, Task::STATE_FINISHED)

  vm.state = Vm::STATE_PAUSED
  vm.save
end

def resume_vm(task)
  puts "resume_vm"

  # here, we are given an id for a VM to start

  begin
    vm = findVM(task)
  rescue
    return
  end

  # OK, marked in the database as already running on a host; let's check it

  if vm.state == Vm::STATE_RUNNING
    # the VM is already paused; just return success
    setTaskState(task, Task::STATE_FINISHED)
    return
  elsif vm.state == Vm::STATE_STOPPED || vm.state == Vm::STATE_SAVED
    # FIXME: hm, we have two options here: either resume the VM and then
    # pause it down below, or fail.  I'm leaning towards fail
    setTaskState(task, Task::STATE_FAILED, "Cannot shutdown paused domain")
    return
  end

  # OK, now that we found the VM, go looking in the hosts table
  begin
    host = findHost(task, vm)
  rescue
    return
  end

  begin
    conn = Libvirt::open("qemu+tcp://" + host.hostname + "/system")
    dom = conn.lookupDomainByUUID(vm.uuid)
    dom.resume
    conn.close
  rescue
    setTaskState(task, Task::STATE_FAILED, "Error looking up domain " + vm.uuid)
    return
  end
  
  setTaskState(task, Task::STATE_FINISHED)
  
  vm.state = Vm::STATE_RUNNING
  vm.save
end

while(true)
  puts 'Checking for tasks...'
  
  Task.find(:all, :conditions => [ "state = ?", Task::STATE_QUEUED ]).each do |task|
    case task.action
    when Task::ACTION_INSTALL_VIRT then create_vm(task)
    when Task::ACTION_SHUTDOWN_VIRT then shutdown_vm(task)
    when Task::ACTION_START_VIRT then start_vm(task)
    when Task::ACTION_PAUSE_VIRT then suspend_vm(task)
    when Task::ACTION_UNPAUSE_VIRT then resume_vm(task)
    when Task::ACTION_SAVE_VIRT then save_vm(task)
    when Task::ACTION_RESTORE_VIRT then restore_vm(task)
    else
      puts "unknown task " + task.action
      setTaskState(task, Task::STATE_FAILED, "Unknown task type")
    end

    task.time_ended = Time.now
    task.save
  end
  
  sleep 5
end
