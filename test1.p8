%import textio
%zeropage basicsafe
%option no_sysinit

; The documentation for custom key handlers can be found here:
; https://github.com/X16Community/x16-docs/blob/master/X16%20Reference%20-%2003%20-%20Editor.md#custom-keyboard-keynum-code-handler

main {

    bool stop_program

    sub start() {
        stop_program = false
        
        txt.print("custom key handler test - press keys! esc to quit!\n")
                

        sys.set_irqd()
        uword old_keyhdl = cx16.KEYHDL
        cx16.KEYHDL = &keyboard_handler
        sys.clear_irqd()

        while not stop_program {
            ; wait
        }

        sys.set_irqd()
        cx16.KEYHDL = old_keyhdl
        sys.clear_irqd()
    }

    sub keyboard_handler(ubyte keynum) -> ubyte {
        ; NOTE: this handler routine expects the keynum in A and return value in A
        ;       which is thankfully how prog8 translates this subroutine's calling convention.
        ; NOTE: it may be better to store the keynum somewhere else and let the main program
        ;       loop figure out what to do with it, rather than putting it all in the handler routine

        txt.print_ubhex(keynum, true)
        ;txt.print_ub(keynum)

        txt.spc()
        if keynum & $80 !=0
            txt.chrout('u')
        else
            txt.chrout('d')
        txt.nl()

        if keynum==$6e {
            ; escape stops the program
            main.stop_program = true
        }
        return 0        ; By returning 0 (in A) we will eat this key event. Return the original keynum value to pass it through.
    }
}






; ; Doubly Linked List with Hash Table Cache
; ; Demonstrates advanced pointer usage with a combination of doubly linked lists and hash tables
; ; for efficient data storage and retrieval


; %import strings
; %import textio
; %zeropage basicsafe

; main {
;     sub start() {
;         txt.lowercase()
;         txt.print("Doubly Linked List with Hash Table Cache Demo\n")
;         txt.print("============================================\n\n")

;         ; Initialize the data structure
;         cache.init()

;         ; Add some sample data
;         txt.print("Adding sample data...\n")
;         cache.add("Alice", true, false,0)
;         cache.add("Bob", true, false,0)
;         cache.add("Charlie", false, false,5)
;         cache.add("Diana", false, false,77)
;         cache.add("Eve", false, false,54)

;         txt.print("\nForward traversal:\n")
;         cache.print_forward()

;         txt.print("\nBackward traversal:\n")
;         cache.print_backward()

;         txt.print("\nSearching for specific entries:\n")
;         txt.print("Looking for 'Charlie': ")
;         ^^cache.Entry entry = cache.find("Charlie")
;         if entry!=0 {
;             txt.print(entry.name)
;             txt.print(" - ")
;             txt.print_bool(entry.is_dir)
;             txt.print(" (")
;             txt.print(" (is_tagged:")
;             txt.print_bool(entry.is_tagged)
;             txt.print(" years old)\n")
;         } else {
;             txt.print("Not found\n")
;         }

;         txt.print("Looking for 'Frank': ")
;         entry = cache.find("Frank")
;         if entry!=0 {
;             txt.print("Found\n")
;         } else {
;             txt.print("Not found\n")
;         }

;         txt.print("\nRemoving 'Bob'...\n")
;         void cache.remove("Bob")

;         txt.print("Forward traversal after removal:\n")
;         cache.print_forward()

;         ; txt.print("\nDemonstrating hash collision handling...\n")
;         ; ; Add entries that will likely collide in the hash table
;         ; cache.add("A", "First", 20)
;         ; cache.add("B", "Second", 21)
;         ; cache.add("C", "Third", 22)
;         ; cache.add("D", "Fourth", 23)
;         ; cache.add("E", "Fifth", 24)

;         ; txt.print("Added entries with potential hash collisions.\n")
;         ; txt.print("Forward traversal:\n")
;         ; cache.print_forward()
;     }
; }




; ; -----------------------------------
; ; --- Linked list
; ; -----------------------------------

; cache {
;     struct Entry {
;         ^^Entry next          ; Next entry in the list
;         ^^Entry prev          ; Previous entry in the list
;         ^^Entry hash_next     ; Next entry in the hash bucket
;         str name              ; Name (key)
;         bool is_dir
;         bool is_tagged
;         uword blocks
;     }

;     const ubyte HASH_TABLE_SIZE = 199
;     ^^Entry[HASH_TABLE_SIZE] hash_table    ; Hash table for fast lookups
;     ^^Entry head = 0                       ; Head of the doubly linked list
;     ^^Entry tail = 0                       ; Tail of the doubly linked list
;     uword count = 0                        ; Number of entries

;     sub init() {
;         ; Initialize hash table buckets to null
;         sys.memsetw(hash_table, HASH_TABLE_SIZE, 0)
;     }

    
; sub add(str name, bool is_dir, bool tagged, uword blocks) {
;         ;--- Create new entry
;         ^^Entry new_record = arena.alloc(sizeof(Entry))

;         ^^ubyte name_copy = arena.alloc(strings.length(name) + 1)
;         void strings.copy(name, name_copy)

;         new_record.name = name_copy
;         new_record.is_dir = is_dir
;         new_record.is_tagged = tagged
;         new_record.blocks = blocks
;         new_record.next = 0
;         new_record.prev = 0
;         new_record.hash_next = 0

;         ; Add to the end of the doubly linked list
;         if head == 0 {
;             ; First entry
;             head = new_record
;             tail = new_record
;         } else {
;             ; Add to the end
;             tail.next = new_record
;             new_record.prev = tail
;             tail = new_record
;         }

;         ; Add to hash table
;         ubyte bucket = strings.hash(name) % HASH_TABLE_SIZE
;         new_record.hash_next = hash_table[bucket]
;         hash_table[bucket] = new_record

;         count++
;     }


;     sub find(str name) -> ^^Entry {
;         ; Find entry using hash table for O(1) average case

;          ;ubyte bucket = strings.hash(name) % HASH_TABLE_SIZE
;          ;^^Entry current = hash_table[bucket]

;         ^^Entry current = head

;         while current != 0 {
;             if strings.compare(current.name, name) == 0
;                 return current
;             ;current = current.hash_next
;             current = current.next
;         }

;         return 0  ; Not found
;     }

;     sub remove(str name) -> bool {
;         ; Find the entry
;         ^^Entry to_remove = find(name)
;         if to_remove == 0
;             return false  ; Not found

;         ; Remove from doubly linked list
;         if to_remove.prev != 0
;             to_remove.prev.next = to_remove.next
;         else
;             head = to_remove.next  ; Was the head

;         if to_remove.next != 0
;             to_remove.next.prev = to_remove.prev
;         else
;             tail = to_remove.prev  ; Was the tail

;         ; Remove from hash table
;         ubyte bucket = strings.hash(name) % HASH_TABLE_SIZE
;         if hash_table[bucket] == to_remove {
;             hash_table[bucket] = to_remove.hash_next
;         } else {
;             ^^Entry current = hash_table[bucket]
;             while current.hash_next != 0 {
;                 if current.hash_next == to_remove {
;                     current.hash_next = to_remove.hash_next
;                     break
;                 }
;                 current = current.hash_next
;             }
;         }

;         count--
;         txt.print("Removed: ")
;         txt.print(name)
;         txt.print("\n")
;         return true
;     }

;     sub print_forward() {
;         ^^Entry current = head
;         while current != 0 {
;             txt.print("- ")
;             txt.print(current.name)
;             txt.print(" (dir:")
;             txt.print_bool(current.is_dir)
;             txt.print(", ")
;             txt.print(" (tagged:")
;             txt.print_bool(current.is_tagged)
;             txt.print(")\n")
;             current = current.next
;         }
;         txt.print("Total entries: ")
;         txt.print_uw(count)
;         txt.print("\n")
;     }

;     sub print_backward() {
;         ^^Entry current = tail
;         while current != 0 {
;             txt.print("- ")
;             txt.print(current.name)
;             txt.print(" (dir:")
;             txt.print_bool(current.is_dir)
;             txt.print(", ")
;             txt.print(" (is_tagged:")
;             txt.print_bool(current.is_tagged)
;             txt.print(")\n")
;             current = current.prev
;         }
;         txt.print("Total entries: ")
;         txt.print_uw(count)
;         txt.print("\n")
;     }
; }

; arena {
;     ; Simple arena allocator
;     uword buffer = memory("arena", 8000, 0)
;     uword next = buffer

;     sub alloc(ubyte size) -> uword {
;         defer next += size
;         return next
;     }
; }
