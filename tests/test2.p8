
%option no_sysinit
%import textio
%import strings
%zeropage basicsafe

main {
    ; Tree node structure with double links
    struct TreeNode {
        uword name_ptr          ; pointer to folder name string
        ubyte depth             ; indentation level (0 = root)
        bool is_expanded       ; 1 if expanded, 0 if collapsed
        bool has_children      ; 1 if has children, 0 if leaf
        ^^TreeNode prev         ; pointer to previous node
        ^^TreeNode next         ; pointer to next node
    }
    
    ^^TreeNode head = 0         ; first node in list
    ^^TreeNode tail = 0         ; last node in list
    ubyte node_count = 0
    ubyte selected_index = 0
    
    ; Folder name storage
    str root_name = "root"
    str folder1 = "documents"
    str folder2 = "pictures"
    str folder3 = "work"
    str folder4 = "personal"
    str folder5 = "games"
    str folder6 = "prog8"
    str folder7 = "projects"
    str folder8 = "music"
    str folder9 = "videos"
    
    sub start() {
        ; Initialize sample tree structure
        init_tree()
        
        ; Main loop
        ubyte running = 1
        draw_tree()
        
        repeat {
            ubyte key = cbm.GETIN2()
            
            when key {
                145 -> {  ; cursor up
                    if selected_index > 0 {
                        selected_index--
                        draw_tree()
                    }
                }
                17 -> {   ; cursor down
                    if selected_index < node_count - 1 {
                        selected_index++
                        draw_tree()
                    }
                }
                13 -> {   ; return - toggle expand/collapse
                    toggle_node_at_index(selected_index)
                    draw_tree()
                }
                'q' -> {  ; quit
                    running = 0
                }
            }
            
            if running == 0
                break
        }
        
        txt.print("\n\ndone!")
    }
    
    sub init_tree() {
        ; Build a sample folder tree
        ; Root
        add_node(root_name, 0, true, true)
        
        ; Level 1
        add_node(folder1, 1, true, true)
        add_node(folder2, 1, false, true)
        add_node(folder5, 1, true, true)
        
        ; Level 2 under documents
        add_node(folder3, 2, false, false)
        add_node(folder4, 2, false, false)
        
        ; Level 2 under games  
        add_node(folder6, 2, false, true)
        
        ; Level 3 under prog8
        add_node(folder7, 3, false, false)
        
        ; More level 1
        add_node(folder8, 1, false, false)
        add_node(folder9, 1, false, false)
    }
    
    sub add_node(uword name, ubyte depth, bool expanded, bool has_children) {
        ; Allocate a new node
        ^^TreeNode new_node = memory("heap", 12, 0)  ; allocate space for TreeNode
        
        ; Initialize the node
        new_node.name_ptr = name
        new_node.depth = depth
        new_node.is_expanded = expanded
        new_node.has_children = has_children
        new_node.next = 0
        
        ; Link into list
        if head == 0 {
            ; First node
            head = new_node
            tail = new_node
            new_node.prev = 0
        } else {
            ; Append to tail
            tail.next = new_node
            new_node.prev = tail
            tail = new_node
        }
        
        node_count++
    }
    
    sub get_node_at_index(ubyte index) -> ^^TreeNode {
        ^^TreeNode current = head
        ubyte i = 0
        
        while current != 0 {
            if i == index
                return current
            current = current.next
            i++
        }
        
        return 0  ; not found
    }
    
    sub toggle_node_at_index(ubyte index) {
        ^^TreeNode node = get_node_at_index(index)
        
        if node != 0 and node.has_children {
            if node.is_expanded {
                node.is_expanded = false
            } else {
                node.is_expanded = true
            }
        }
    }
    
    sub draw_tree() {
        txt.clear_screen()
        txt.print("folder tree control (linked list)\n")
        txt.print("----------------------------------\n")
        txt.print("up/down: navigate  enter: expand/collapse  q: quit\n\n")
        
        ^^TreeNode current = head
        ubyte i = 0
        
        while current != 0 {
            ; Check if node should be visible
            bool visible = is_node_visible_ptr(current)
            
            if visible {
                ; Highlight selected item
                if i == selected_index {
                    txt.print("> ")
                } else {
                    txt.print("  ")
                }
                
                ; Draw indentation
                ubyte j
                ubyte depth = current.depth
                for j in 0 to depth-1 {
                    txt.print("  ")
                }
                
                ; Draw expand/collapse indicator
                if current.has_children {
                    if current.is_expanded {
                        txt.chrout('-')  ; expanded
                    } else {
                        txt.chrout('+')  ; collapsed
                    }
                } else {
                    txt.chrout(' ')  ; leaf node
                }
                
                txt.chrout(' ')
                txt.print(current.name_ptr)
                txt.nl()
            }
            
            current = current.next
            i++
        }
    }
    
    sub is_node_visible_ptr(^^TreeNode node) -> bool {
        if node.depth == 0
            return true  ; root is always visible
        
        ; Walk backwards through list to find parent
        ^^TreeNode current = node.prev
        ubyte target_depth = node.depth - 1
        
        while current != 0 {
            if current.depth == target_depth {
                ; Found parent
                if current.is_expanded == false
                    return false  ; parent collapsed
                target_depth--
                if target_depth == 0
                    break
            }
            current = current.prev
        }
        
        return true
    }
}


;===============================================================================================
;===============================================================================================
;===============================================================================================
;===============================================================================================




; %import diskio
; %import textio
; %import strings
; %import namesorting
; %zeropage basicsafe
; %option no_sysinit

; ; STANDALONE PROGRAM INCLUDING THE FILE SELECTOR CODE.

; ; A "TUI" for an interactive file selector, that scrolls the selection list if it doesn't fit on the screen.
; ; Returns the name of the selected file.  If it is a directory instead, the name will start and end with a slash '/'.
; ; Works in PETSCII mode and in ISO mode as well (no case folding in ISO mode!)

; ; TODO keyboard typing; jump to the first entry that starts with that character?  (but 'q' for quit stops working then, plus scrolling with pageup/down is already pretty fast)


; main {
;     ^^ubyte chosen
;     sub start() {
;         ; some configuration, optional
;         ;fileselector.configure_settings(8, 3, 2)
;         ;fileselector.configure_appearance(10, 10, 12, $b3, $d0)

;         ; show all files, using just the * wildcard
;         str diskname1 = "?"*32
;         void strings.copy(diskio.diskname(),diskname1)
;         str orginal_dir = "?"*60 
;         void strings.copy(diskio.curdir(),orginal_dir)
        
;         ;diskio.chdir("/docs/")
;         chosen = fill_me("*")

;         repeat 2 txt.nl()
;         ;txt.nl()



;         if chosen!=0 {
            
;             if strings.startswith(chosen,"/") {
;                 txt.print(chosen)
;                 str yy = "?"*32
;                 void strings.copy(chosen,yy)
;                 diskio.chdir(yy)
;                 chosen = fill_me("*")
;                 ;txt.print("1chosen: ")
;                 ;txt.print(chosen)
;                 ;txt.nl()
;             } else {
;                 txt.print("chosen: ")
;                 txt.print(chosen)
;                 txt.nl()
;             }


;         } else {
        
;             txt.print("nothing chosen or error!\n")
;             txt.print(diskio.status())
;             diskio.chdir(orginal_dir)
;         }
;         return
;     }

    
;     sub fill_me(str cdir) . ^^ubyte {
;         fileselector.configure_settings(8, 3, 2)
;         fileselector.configure_appearance(10, 10, 12, $b3, $d0)
;         chosen = fileselector.select(cdir)
;         return chosen
;     }

; }


; fileselector {
;     %option ignore_unused

;     const uword filenamesbuffer = $a000      ; use a HIRAM bank
;     const uword filenamesbuf_size = $1e00    ; leaves room for a 256 entry string pointer table at $be00-$bfff
;     const uword filename_ptrs_start = $be00  ; array of 256 string pointers for each of the names in the buffer. ends with $0000.

;     ubyte dialog_topx = 10
;     ubyte dialog_topy = 10
;     ubyte max_lines = 18
;     ubyte colors_normal = $b3
;     ubyte colors_selected = $d0
;     ubyte buffer_rambank = 1    ; default hiram bank to use for the data buffers
;     ubyte show_what = 3         ; dirs and files
;     ubyte chr_topleft, chr_topright, chr_botleft, chr_botright, chr_horiz_top, chr_horiz_other, chr_vert, chr_jointleft, chr_jointright
;     bool draw_box_info = false

;     ubyte num_visible_files
;     ^^ubyte name_ptr


;     sub configure_settings(ubyte drivenumber, ubyte show_types, ubyte rambank) {
;         ; show_types is a bit mask , bit 0 = include files in list, bit 1 = include dirs in list,   0 (or 3)=show everything.
;         diskio.drivenumber = drivenumber
;         buffer_rambank = rambank
;         show_what = show_types
;         if_z
;             show_what = 3
;         ;set_characters(false)
;     }

;     sub configure_appearance(ubyte column, ubyte row, ubyte max_entries, ubyte normal, ubyte selected) {
;         dialog_topx = column
;         dialog_topy = row
;         max_lines = max_entries
;         colors_normal = normal
;         colors_selected = selected
;     }

;     sub select(str pattern) . str {
;         str defaultpattern="*"
;         if pattern==0
;             pattern = &defaultpattern
;         sys.push(cx16.getrambank())
;         cx16.r0 = internal_select(pattern)
;         cx16.rambank(sys.pop())
;         return cx16.r0
;     }

;     sub internal_select(str pattern) . str {
;         num_visible_files = 0
;         diskio.list_filename[0] = 0
;         name_ptr = diskio.diskname()
;         if name_ptr==0 or cbm.READST()!=0
;             return 0

;         bool iso_mode = cx16.get_charset()==1
;         ;     txt.print_ub(diskio.drivenumber)

;         ubyte num_files = get_names(pattern, filenamesbuffer, filenamesbuf_size)    ; use Hiram bank to store the files
;         ubyte selected_line
;         ubyte top_index
;         uword filename_ptrs

;         construct_name_ptr_array()
;         ; sort alphabetically
;         sorting.shellsort_pointers(filename_ptrs_start, num_files)
;         num_visible_files = min(max_lines, num_files)

;         background(5, 3 + num_visible_files -1)
;         txt.plot(dialog_topx+2, dialog_topy+2)
;         repeat 4 txt.nl()
        
;         if num_files>0 {
;             for selected_line in 0 to num_visible_files-1 {
;                 txt.column(dialog_topx+1)
;                 ;txt.column(dialog_topx)
;                 ;txt.chrout(chr_vert)
;                 txt.spc()
;                 print_filename(peekw(filename_ptrs_start+selected_line*$0002))
;                 txt.column(dialog_topx+31)
;                 ;txt.chrout(chr_vert)
;                 txt.nl()
;             }
;         } else {
;             txt.column(dialog_topx+1)
;             ;txt.column(dialog_topx)
;             ;txt.chrout(chr_vert)
;             txt.print(" no matches.")
;             txt.column(dialog_topx+31)
;             ;txt.chrout(chr_vert)
;             txt.nl()
;         }
;         print_scroll_indicator(false, false)
;         txt.column(dialog_topx)
;         ;footerline()
;         selected_line = 0
;         select_line(0)
;         print_up_and_down()

;         repeat {
;             if cbm.STOP2()
;                 return 0

;             ubyte key = cbm.GETIN2()
;             cx16.r0 = cx16.joysticks_getall(false)
;             if cx16.r0L!=0
;                 sys.wait(4)
;             ror(cx16.r0L)
;             if_cs
;                 key = ']'   ; right
;             ror(cx16.r0L)
;             if_cs
;                 key = '['   ; left
;             ror(cx16.r0L)
;             if_cs
;                 key = 17    ; down
;             ror(cx16.r0L)
;             if_cs
;                 key = 145   ; up
;             if cx16.r0L & $0f != 0
;                 key = '\n'  ; select file
;             if cx16.r0H != 0
;                 key = 27    ; cancel


;             when key {
;                 3, 27 . return 0      ; STOP and ESC  aborts
;                 '\n',' ' . {
;                     if num_files>0 {
;                         void strings.copy(peekw(filename_ptrs_start + (top_index+selected_line)*$0002), &diskio.list_filename)
;                         return diskio.list_filename
;                     }
;                     return 0
;                 }
;                 '[',130,157 . {    ; PAGEUP, cursor left
;                     ; previous page of lines
;                     unselect_line(selected_line)
;                     if selected_line==0
;                         repeat max_lines scroll_list_backward()
;                     selected_line = 0
;                     select_line(0)
;                     print_up_and_down()
;                 }
;                 ']',2,29 . {      ; PAGEDOWN, cursor right
;                     if num_files>0 {
;                         ; next page of lines
;                         unselect_line(selected_line)
;                         if selected_line == max_lines-1
;                             repeat max_lines scroll_list_forward()
;                         selected_line = num_visible_files-1
;                         select_line(selected_line)
;                         print_up_and_down()
;                     }
;                 }
;                 17 . {     ; down
;                     if num_files>0 {
;                         unselect_line(selected_line)
;                         if selected_line<num_visible_files-1
;                             selected_line++
;                         else if num_files>max_lines
;                             scroll_list_forward()
;                         select_line(selected_line)
;                         print_up_and_down()
;                     }
;                 }
;                 145 . {    ; up
;                     unselect_line(selected_line)
;                     if selected_line>0
;                         selected_line--
;                     else if num_files>max_lines
;                         scroll_list_backward()
;                     select_line(selected_line)
;                     print_up_and_down()
;                 }
;             }
;         }

;         ubyte x,y

;         sub construct_name_ptr_array() {
;             filename_ptrs = filename_ptrs_start
;             name_ptr = filenamesbuffer
;             repeat num_files {
;                 pokew(filename_ptrs, name_ptr)
;                 if iso_mode {
;                     ; no case folding in iso mode
;                     while @(name_ptr)!=0
;                         name_ptr++
;                 } else {
;                     ; case-folding to avoid petscii shifted characters coming out as symbols
;                     ; Q: should diskio do this already? A: no, diskio doesn't know or care about the current charset mode
;                     name_ptr += strings.lower(name_ptr)
;                 }
;                 name_ptr++
;                 filename_ptrs+=2
;             }
;             pokew(filename_ptrs, 0)
;         }

;         sub print_filename(str name) {
;             repeat 28 {      ; maximum length displayed
;                 if @(name)==0
;                     break
;                 txt.chrout(128)     ; don't print control characters
;                 txt.chrout(@(name))
;                 name++
;             }
;         }

;         sub scroll_list_forward() {
;             if top_index+max_lines< num_files {
;                 top_index++
;                 ; scroll the displayed list up 1
;                 scroll_txt_up(dialog_topx+2, dialog_topy+6, 28, max_lines, sc:' ')
;                 ; print new name at the bottom of the list
;                 txt.plot(dialog_topx+2, dialog_topy+6+max_lines-1)
;                 print_filename(peekw(filename_ptrs_start + (top_index+ selected_line)*$0002))
;             }
;         }

;         sub scroll_list_backward() {
;             if top_index>0 {
;                 top_index--
;                 ; scroll the displayed list down 1
;                 scroll_txt_down(dialog_topx+2, dialog_topy+6, 28, max_lines, sc:' ')
;                 ; print new name at the top of the list
;                 txt.plot(dialog_topx+2, dialog_topy+6)
;                 print_filename(peekw(filename_ptrs_start + top_index * $0002))
;             }
;         }

;         sub scroll_txt_up(ubyte col, ubyte row, ubyte width, ubyte height, ubyte fillchar) {
;             for y in row to row+height-2 {
;                 for x in col to col+width-1 {
;                     txt.setchr(x,y, txt.getchr(x, y+1))
;                 }
;             }
;             y = row+height-1
;             for x in col to col+width-1 {
;                 txt.setchr(x,y, fillchar)
;             }
;         }

;         sub scroll_txt_down(ubyte col, ubyte row, ubyte width, ubyte height, ubyte fillchar) {
;             for y in row+height-1 downto row+1 {
;                 for x in col to col+width-1 {
;                     txt.setchr(x,y, txt.getchr(x, y-1))
;                 }
;             }
;             for x in col to col+width-1 {
;                 txt.setchr(x,row, fillchar)
;             }
;         }

;         sub print_up_and_down() {
;             if num_files<=max_lines
;                 return
;             print_scroll_indicator(top_index>0, true)
;             print_scroll_indicator(top_index + num_visible_files < num_files, false)
;         }

;         sub print_scroll_indicator(bool visible, bool up) {
;             txt.plot(dialog_topx, dialog_topy + (if up  5  else  6+num_visible_files))
;             ;txt.chrout(chr_vert)
;             txt.column(dialog_topx+24)
;             if visible
;                 if up
;                     txt.print("  (up)")
;                 else
;                     txt.print("(down)")
;             else
;                 txt.print("      ")
;             txt.spc()
;             ;txt.chrout(chr_vert)
;             txt.nl()
;         }

;         sub select_line(ubyte line) {
;             line_color(line, colors_selected)
;         }

;         sub unselect_line(ubyte line) {
;             line_color(line, colors_normal)
;         }

;         sub line_color(ubyte line, ubyte colors) {
;             cx16.r1L = dialog_topy+6+line
;             ubyte charpos
;             for charpos in dialog_topx+1 to dialog_topx+30 {
;                 txt.setclr(charpos, cx16.r1L, colors)
;             }
;         }
;     }

;     sub background(ubyte startrow, ubyte numlines) {
;         startrow += dialog_topy
;         repeat numlines {
;             txt.plot(dialog_topx+1, startrow)
;             repeat 30  txt.chrout(' ')
;             txt.nl()
;             startrow++
;         }
;     }

;     sub get_names(str pattern_ptr, uword filenames_buffer, uword filenames_buf_size) . ubyte {
;         uword buffer_start = filenames_buffer
;         ubyte files_found = 0
;         filenames_buffer[0]=0
;         bool list_ok

;         when show_what {
;             1 . list_ok = diskio.lf_start_list_files(pattern_ptr)
;             2 . list_ok = diskio.lf_start_list_dirs(pattern_ptr)
;             else . list_ok = diskio.lf_start_list(pattern_ptr)
;         }

;         if list_ok {
;             while diskio.lf_next_entry() {
              
;                 str tmp9=" "
;                 void strings.copy(diskio.list_filename, tmp9)
;                 ;--- we do not want anything that starts with a . Thats a hidden file
;                 if strings.startswith(tmp9,".")
;                     continue

;                 bool is_dir = diskio.list_filetype=="dir"
;                 if is_dir and show_what & 2 == 0
;                     continue
;                 if not is_dir and show_what & 1 == 0
;                     continue
;                 if is_dir {
;                     @(filenames_buffer) = '/'       ; directories start with a slash so they're grouped when sorting
;                     filenames_buffer++
;                 }
;                 filenames_buffer += strings.copy(diskio.list_filename, filenames_buffer)
;                 if is_dir {
;                     @(filenames_buffer) = '/'       ; directories also end with a slash
;                     filenames_buffer++
;                     @(filenames_buffer) = 0
;                 }
;                 filenames_buffer++
;                 files_found++
;                 if filenames_buffer - buffer_start > filenames_buf_size-20 {
;                     @(filenames_buffer)=0
;                     diskio.lf_end_list()
;                     sys.set_carry()
;                     return files_found
;                 }
;             }
;             diskio.lf_end_list()
;         }
;         @(filenames_buffer)=0
;         sys.clear_carry()
;         return files_found
;     }

; }
