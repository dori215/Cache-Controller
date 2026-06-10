`timescale 1ns / 1ps

module cache_tb;

    // Semnale de intrare
    reg clk;
    reg reset;
    reg read;
    reg write;
    reg [31:0] address;
    reg [31:0] write_data_word;
    reg [511:0] mem_read_block;
    reg mem_ready;

    // Semnale de iesire
    wire [31:0] read_data_word;
    wire hit;
    wire miss;
    wire mem_read;
    wire mem_write;
    wire [31:0] mem_address;
    wire [511:0] mem_write_block;

    // Instantierea modulului Cache Controller
    cache_controller uut (
        .clk(clk),
        .reset(reset),
        .read(read),
        .write(write),
        .address(address),
        .write_data_word(write_data_word),
        .read_data_word(read_data_word),
        .hit(hit),
        .miss(miss),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .mem_address(mem_address),
        .mem_write_block(mem_write_block),
        .mem_read_block(mem_read_block),
        .mem_ready(mem_ready)
    );

    // Generarea semnalului de ceas (Perioada = 10ns)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Simularea comportamentului Memoriei Principale (RAM)
    always @(posedge clk) begin
        if (mem_read || mem_write) begin
            // Introducem un delay artificial de 2 cicluri de ceas pentru a imita RAM-ul
            #20; 
            mem_ready = 1;
            if (mem_read) begin
                // Generam niste date dummy pentru a fi citite de cache
                mem_read_block = {16{32'hDEADBEEF}}; // Umplem blocul cu DEADBEEF
            end
        end else begin
            mem_ready = 0;
        end
    end

    // Secventa de testare
    initial begin
        // Initializare semnale
        reset = 1;
        read = 0;
        write = 0;
        address = 0;
        write_data_word = 0;
        mem_read_block = 0;

        // Resetare sistem
        #20;
        reset = 0;
        #10;

        $display("--- INCEPERE SIMULARE ---");

        // TEST 1: READ MISS (Cache-ul este gol)
        $display("Test 1: Read Miss la adresa 0x00000000");
        address = 32'h0000_0000;
        read = 1;
        wait(hit || miss); // Asteptam decizia FSM-ului
        #10;
        read = 0;
        #40; // Asteptam finalizarea alocarii din RAM

        // TEST 2: READ HIT (Citim aceeasi adresa)
        $display("Test 2: Read Hit la adresa 0x00000000");
        address = 32'h0000_0000;
        read = 1;
        wait(hit || miss);
        #10;
        read = 0;
        #20;

        // TEST 3: WRITE HIT (Modificam cuvantul din cache)
        $display("Test 3: Write Hit la adresa 0x00000000");
        address = 32'h0000_0000;
        write_data_word = 32'hCAFEBABE;
        write = 1;
        wait(hit || miss);
        #10;
        write = 0;
        #20;

        // TEST 4: UMPLEREA SETULUI (Fortam ocuparea celorlalte 3 cai)
        // Folosim acelasi Index (0) dar Tag-uri diferite
        $display("Test 4: Umplerea Setului 0");
        
        // Way 1
        address = 32'h0000_2000; // Tag 1, Index 0
        read = 1; wait(hit || miss); #10; read = 0; #40;
        
        // Way 2
        address = 32'h0000_4000; // Tag 2, Index 0
        read = 1; wait(hit || miss); #10; read = 0; #40;
        
        // Way 3
        address = 32'h0000_6000; // Tag 3, Index 0
        read = 1; wait(hit || miss); #10; read = 0; #40;

        // TEST 5: EVICT LRU CU WRITE-BACK
        // Calea 0 este cea mai veche accesata si e DIRTY (de la Test 3)
        $display("Test 5: Evict pe Way 0 (Dirty) cu Write-Back");
        address = 32'h0000_8000; // Tag 4, Index 0 -> Va forta evacuarea
        read = 1;
        wait(hit || miss);
        #10;
        read = 0;
        #80; // Asteptam evacuarea si noua alocare

        $display("--- SIMULARE FINALIZATA ---");
       // TEST 6: WRITE MISS (Scriem la o adresa noua - Index 1)
       $display("Test 6: Write Miss la adresa 0x00000040");
        address = 32'h0000_0040; // O adresa care pica pe Indexul 1 (complet gol)
        write_data_word = 32'hFACEB00C;
        write = 1;
        wait(hit || miss);
        #10;
        write = 0;
        #40; // Asteptam alocarea din RAM si scrierea cuvantului
        $stop; // Opreste simularea in ModelSim
    end

endmodule
