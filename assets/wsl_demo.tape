# VHS script for native WSL Linux zzh demo
# To run this: vhs assets/wsl_demo.tape

Output assets/demo.gif

Set Shell bash
Set FontSize 15
Set FontFamily "Fira Code"
Set Width 1100
Set Height 650
Set Padding 20
Set Theme "Builtin Dark"

# Speed settings
Set TypingSpeed 50ms
Set PlaybackSpeed 1

# Start the recording
Sleep 1s

# Silently setup the local environment with colors/prompt
Hide
Type "source assets/bashrc && clear"
Enter
Sleep 500ms
Show

# 1. Show local environment
Type "hostname"
Sleep 500ms
Enter
Sleep 1.5s

# 2. Run zzh with single binary. It will prompt for password and selection.
Type "./zig-out/bin/zzh -p 2222 root@127.0.0.1 +s bash +d assets/bashrc ++tmux +b zoxide"
Sleep 1s
Enter

# Type the password when prompted
Sleep 2s
Type "test"
Enter

# Handle binary REPO selection (Top 3)
Sleep 3.5s
Type "1"
Enter

# Handle binary ASSET selection
Sleep 2s
Type "1"
Enter

# Connection and provisioning
Sleep 8s

# 3. Remote hostname (proves connection succeeded)
Type "hostname"
Sleep 500ms
Enter
Sleep 2.5s

# 4. Show remote environment (inherited look)
Type "ls -la"
Sleep 500ms
Enter
Sleep 2.5s

# 5. Check tmux session
Type "tmux ls"
Sleep 500ms
Enter
Sleep 2.5s

# 6. Verify zoxide works remotely
Type "zoxide --version"
Sleep 500ms
Enter
Sleep 3s

# 7. Exit remote session
Type "exit"
Sleep 500ms
Enter
Sleep 2s

# 8. Return to local
Type "hostname"
Sleep 500ms
Enter
Sleep 1.5s

# 9. Clear for loop
Type "clear"
Sleep 500ms
Enter
Sleep 1.5s
