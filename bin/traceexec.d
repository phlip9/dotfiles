#!/usr/sbin/dtrace -C -s
#pragma D option quiet

dtrace:::BEGIN 
{
    printf("PID\tPPID\tTIME\tPATH\tARGV\n")
}

syscall::execve:entry
/pid == $target || progenyof($target)/
{
    this->path = copyinstr(arg0);
    this->argv = args[1];
}

syscall::posix_spawn:entry
/pid == $target || progenyof($target)/
{
    this->path = copyinstr(arg1);
    this->argv = args[3];
}

#define SAFE_ARGC(idx) ((this->argc != (idx) || this->argv[(idx)] == NULL) ? this->argc : (this->argc + 1))
#define SAFE_ARGV(idx) ((this->argc > (idx)) ? copyinstr((user_addr_t) this->argv[(idx)]) : "")

syscall::execve:entry,
syscall::posix_spawn:entry
/pid == $target || progenyof($target)/
{
    this->pid=pid;
    this->ppid=ppid;

    // DTrace doesn't support loops, so we have to manually unroll the argc
    // and argv processing.

    this->argc = 0;
    this->argc = SAFE_ARGC(0);
    this->argc = SAFE_ARGC(1);
    this->argc = SAFE_ARGC(2);
    this->argc = SAFE_ARGC(3);
    this->argc = SAFE_ARGC(4);
    this->argc = SAFE_ARGC(5);
    this->argc = SAFE_ARGC(6);
    this->argc = SAFE_ARGC(7);
    this->argc = SAFE_ARGC(8);
    this->argc = SAFE_ARGC(9);
    
    printf("%d\t", pid);
    printf("%d\t", ppid);
    printf("%Y\t", walltimestamp);
    printf("%s\t", this->path);
    printf("%s ", SAFE_ARGV(1));
    printf("%s ", SAFE_ARGV(2));
    printf("%s ", SAFE_ARGV(3));
    printf("%s ", SAFE_ARGV(4));
    printf("%s ", SAFE_ARGV(5));
    printf("%s ", SAFE_ARGV(6));
    printf("%s ", SAFE_ARGV(7));
    printf("%s ", SAFE_ARGV(8));
    printf("%s ", SAFE_ARGV(9));
    printf("\n");
}

#undef SAFE_ARGC
#undef SAFE_ARGV
