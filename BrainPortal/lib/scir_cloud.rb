
#
# CBRAIN Project
#
# Copyright (C) 2008-2012
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.  
#

# This is a replacement for the drmaa.rb library; this particular subclass
# of class Scir implements a dummy cluster interface that still runs
# jobs locally as standard unix subprocesses.


# An abstract Scir class to access clouds.
class ScirCloud < Scir
  
  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  # An abstract method that returns an array containing instance types
  # available on this cloud, for instance:
  #     ["m1.small", "m2.large"]  
  def self.get_available_instance_types(bourreau)
    raise "Needs to be implemented in a sub-class"
  end

  # An abstract method that returns an array containing arrays of size
  # 2 with the ids and names of disk images available to the bourreau,
  # for instance:
  #     [ ["CentOS7","ami-12345"], ["CentOS6","ami-6789"] ]
  # This (weird) data structure is used to pass the result of this method in a Rails select tag.
  def self.get_available_disk_images(bourreau)
    raise "Needs to be implemented in a sub-class"
  end
  
  # An abstract method that returns an array containing arrays of size
  # 1 with the ids the key pairs available to the bourreau,
  # for instance:
  #     [ ["id_rsa_cbrain_portal"], ["personal_key"] ]
  # This (weird) data structure is used to pass the result of this method in a Rails select tag.
  def self.get_available_key_pairs(bourreau)
    raise "Needs to be implemented in a sub-class"
  end

  # Terminates the VM.
  def terminate_vm(jid)
    raise "Needs to be implemented in a sub-class"
  end

  # TODO: doc todo, based on the doc in scir_amazon
  def submit_vm(vm_name,image_id,key_name,instance_type,tag_value)
    raise "Needs to be implemented in a sub-class"
  end

  # Not supported
  def hold_vm(jid)
    raise "Needs to be implemented in a sub-class"
  end
  
  # Not supported
  def release_vm(jid)
    raise "Needs to be implemented in a sub-class"
  end
  
  # Not supported
  def suspend_vm(jid)
    raise "Needs to be implemented in a sub-class"
  end
  
  # Not supported
  def resume(jid)
    raise "Needs to be implemented in a sub-class"
  end
  
  # Not supported
  def hold(jid)
    cbrain_task = CbrainTask.find(job.task_id)
    raise "Not supported" if is_vm_task?(cbrain_task)
    true # as in scir_unix
  end
  
  # Not supported
  def release(jid)
    cbrain_task = CbrainTask.find(job.task_id)
    raise "Not supported" if is_vm_task?(cbrain_task)
    true # as in scir_unix
  end
  
  # Not supported
  def suspend(jid)
    cbrain_task = CbrainTask.find(job.task_id)
    if is_vm_task?(cbrain_task)
      terminate_vm(cbrain_task)
    else
      pid = get_pid(jid)
      command = "kill -STOP #{pid}"
      vm_task.run_command_in_vm(command)
    rescue => ex
      raise ex unless ex.message.include? "Cannot establish connection with VM" #if the VM executing this task cannot be reached, then the task should be put in status terminated. Otherwise, if VM shuts down and the task is still in there, it could never be terminated.
    end
  end
  
  # Not supported
  def resume(jid)
    cbrain_task = CbrainTask.find(job.task_id)
    if is_vm_task?(cbrain_task)
      terminate_vm(cbrain_task)
    else
      pid = get_pid(jid)
      command = "kill -CONT #{pid}"
      vm_task.run_command_in_vm(command)
    rescue => ex
      raise ex unless ex.message.include? "Cannot establish connection with VM" #if the VM executing this task cannot be reached, then the task should be put in status terminated. Otherwise, if VM shuts down and the task is still in there, it could never be terminated.
    end
  end

  # Terminates the VM.
  def terminate(jid)
    cbrain_task = CbrainTask.find(job.task_id)
    if is_vm_task?(cbrain_task)
      terminate_vm(cbrain_task)
    else
      pid = get_pid(jid)
      command = "kill -TERM #{pid}"
      vm_task.run_command_in_vm(command)
    rescue => ex
      raise ex unless ex.message.include? "Cannot establish connection with VM" #if the VM executing this task cannot be reached, then the task should be put in status terminated. Otherwise, if VM shuts down and the task is still in there, it could never be terminated.
    end
  end
    
  # TODO: doc. Overrides the 'run' method of class Scir. 
  def run(job)
    cbrain_task = CbrainTask.find(job.task_id)

    # The task is a VM, it must be submitted to the cloud
    if is_vm_task?(cbrain_task)
      vm = submit_VM("CBRAIN Worker", cbrain_task.params[:disk_image], cbrain_task.params[:ssh_key_pair],cbrain_task.params[:instance_type], "CBRAIN worker") 
      return vm.instance_id.to_s
    end

    # The task needs to be executed in a VM
    vm_task = CbrainTask.find(cbrain_task.vm_id)
    raise "VM task #{vm_task.id} is not a VM task (it is a #{vm_task.class.name})." unless is_vm_task?(vm_task)
    vm_task.mount_directories # raises an exception if directories cannot be mounted
    command = job.qsub_command
    pid = vm_task.run_command_in_vm(command).gsub("\n","")  
    return create_job_id(vm_task.id,pid)
    
  end

  # The JobTemplate class.
  class JobTemplate < Scir::JobTemplate
    # This method seems required, although in a ScirCloud the
    # qsub_command is never used.
    def qsub_command
      cbrain_task = CbrainTask.find(task_id)
      return "echo This is never executed" if cbrain_task.is_vm_task?

      # The task will be executed in a VM
      command = qsub_command_scir_unix
      command.sub!(cbrain_task.full_cluster_workdir,File.join(File.basename(RemoteResource.current_resource.cms_shared_dir),task.cluster_workdir)) #TODO (VM tristan) fix these awful substitutions #4769
      command.gsub!(cbrain_task.full_cluster_workdir,"./")  
      command+=" & echo \$!" #so that the command is backgrounded and its PID is returned
    end    

    def shell_escape(s) #:nodoc:
      "'" + s.gsub(/'/,"'\\\\''") + "'"
    end

    # TODO: call the method from scir unix instead of copying it here.
    def qsub_command_scir_unix #:nodoc:
      raise "Error, this class only handle 'command' as /bin/bash and a single script in 'arg'" unless
        self.command == "/bin/bash" && self.arg.size == 1
      raise "Error: stdin not supported" if self.stdin

      stdout = self.stdout || ":/dev/null"
      stderr = self.stderr || (self.join ? nil : ":/dev/null")

      stdout.sub!(/^:/,"") if stdout
      stderr.sub!(/^:/,"") if stderr

      command = ""
      command += "cd #{shell_escape(self.wd)} || exit 20;"  if self.wd
      command += "/bin/bash #{shell_escape(self.arg[0])}"
      command += "  > #{shell_escape(stdout)}"
      command += " 2> #{shell_escape(stderr)}"              if stderr
      command += " 2>&1"                                    if self.join && stderr.blank?

      return command
    end

  end


  private: 
    def create_job_id(vm_id,pid) #:nodoc:
      raise "Error submissing job to VM #{vm_task.id}" if pid.to_s==""
      raise "\"#{pid}\" doesn't look like a valid PID" unless pid.to_s.is_an_integer?
      return "VM:#{vm_id}:#{pid}"
    end
    def get_pid(jid) #:nodoc:
      raise "Invalid job id" unless is_valid_jobid?(jid)
      s = jid.split(":")
      return s[2]
    end
    def is_valid_jobid?(job_id) #:nodoc:
      s=job_id.split(":")
      return false if s.size != 3
      return false if s[0] != "VM"
      return true
    end
end

