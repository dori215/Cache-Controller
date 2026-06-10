`timescale 1ns / 1ps

module cache_controller (
    input wire clk,
    input wire reset,
    
    // Interfata cu Procesorul (CPU)
    input wire read,
    input wire write,
    input wire [31:0] address,
    input wire [31:0] write_data_word, // Procesorul transfera date la nivel de cuvant (32 biti)
    output reg [31:0] read_data_word,
    output reg hit,
    output reg miss,
    
    // Interfata cu Memoria Principala (RAM)
    output reg mem_read,
    output reg mem_write,
    output reg [31:0] mem_address,
    output reg [511:0] mem_write_block, // Transferul se face la nivel de bloc (512 biti / 64 bytes)
    input wire [511:0] mem_read_block,
    input wire mem_ready                // Semnal de confirmare de la RAM
);

    // 1. Parametrii Generali ai Cache-ului
    localparam NUM_SETS = 128;   
    localparam BLOCK_SIZE = 512; 
    localparam TAG_WIDTH = 19;
    localparam INDEX_WIDTH = 7;
    localparam OFFSET_WIDTH = 6;

    // Descompunerea adresei de 32 de biti primite de la procesor
    wire [TAG_WIDTH-1:0]   addr_tag    = address[31:13];
    wire [INDEX_WIDTH-1:0] addr_index  = address[12:6];
    wire [3:0]             word_offset = address[5:2]; // Folosit pentru MUX-ul de 16:1

    // 2. Definirea Starilor FSM (Automatul de Control)
    localparam IDLE       = 3'b000;
    localparam READ_HIT   = 3'b001;
    localparam WRITE_HIT  = 3'b010;
    localparam READ_MISS  = 3'b011;
    localparam WRITE_MISS = 3'b100;
    localparam EVICT      = 3'b101;
    localparam ALLOCATE   = 3'b110;

    reg [2:0] current_state, next_state;
	
    // 3. Matricele de Memorie (Arhitectura 4-Way Set Associative)
    // Calea 0 (Way 0)
    reg valid0 [0:NUM_SETS-1];
    reg dirty0 [0:NUM_SETS-1];
    reg [1:0] lru_cnt0 [0:NUM_SETS-1]; // Contor LRU pentru determinarea celei mai vechi utilizari
    reg [TAG_WIDTH-1:0] tag0 [0:NUM_SETS-1];
    reg [BLOCK_SIZE-1:0] data0 [0:NUM_SETS-1];

    // Calea 1 (Way 1)
    reg valid1 [0:NUM_SETS-1];
    reg dirty1 [0:NUM_SETS-1];
    reg [1:0] lru_cnt1 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag1 [0:NUM_SETS-1];
    reg [BLOCK_SIZE-1:0] data1 [0:NUM_SETS-1];

    // Calea 2 (Way 2)
    reg valid2 [0:NUM_SETS-1];
    reg dirty2 [0:NUM_SETS-1];
    reg [1:0] lru_cnt2 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag2 [0:NUM_SETS-1];
    reg [BLOCK_SIZE-1:0] data2 [0:NUM_SETS-1];

    // Calea 3 (Way 3)
    reg valid3 [0:NUM_SETS-1];
    reg dirty3 [0:NUM_SETS-1];
    reg [1:0] lru_cnt3 [0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0] tag3 [0:NUM_SETS-1];
    reg [BLOCK_SIZE-1:0] data3 [0:NUM_SETS-1];

    // 4. Logica de Cautare Paralela (Hit/Miss Logic)
    // Verificam simultan daca Tag-ul coincide si blocul este valid
    wire hit0 = valid0[addr_index] && (tag0[addr_index] == addr_tag);
    wire hit1 = valid1[addr_index] && (tag1[addr_index] == addr_tag);
    wire hit2 = valid2[addr_index] && (tag2[addr_index] == addr_tag);
    wire hit3 = valid3[addr_index] && (tag3[addr_index] == addr_tag);
    
    wire any_hit = hit0 | hit1 | hit2 | hit3; // Semnalul de Hit global (Poarta SAU)

    // 5. Selectia Caii de Evacuare (Logica LRU)
    // Identificam calea care are contorul 00 (Least Recently Used)
    wire [1:0] evict_way =  (lru_cnt0[addr_index] == 2'b00) ? 2'b00 :
                            (lru_cnt1[addr_index] == 2'b00) ? 2'b01 :
                            (lru_cnt2[addr_index] == 2'b00) ? 2'b10 : 2'b11;

    // Extragem datele caii alese pentru a fi eventual salvate in RAM (Write-Back)
    wire evict_dirty =  (evict_way == 2'b00) ? dirty0[addr_index] :
                        (evict_way == 2'b01) ? dirty1[addr_index] :
                        (evict_way == 2'b10) ? dirty2[addr_index] : dirty3[addr_index];

    wire [TAG_WIDTH-1:0] evict_tag =    (evict_way == 2'b00) ? tag0[addr_index] :
                                        (evict_way == 2'b01) ? tag1[addr_index] :
                                        (evict_way == 2'b10) ? tag2[addr_index] : tag3[addr_index];

    wire [BLOCK_SIZE-1:0] evict_data =  (evict_way == 2'b00) ? data0[addr_index] :
                                        (evict_way == 2'b01) ? data1[addr_index] :
                                        (evict_way == 2'b10) ? data2[addr_index] : data3[addr_index];

    // 6. Extragerea Datelor (Multiplexoarele din Block Diagram)
    reg [BLOCK_SIZE-1:0] active_block;
    
    always @(*) begin
        // Primul nivel de decizie: MUX 4:1 (Alegem blocul castigator de 512 biti)
        if (hit0) active_block = data0[addr_index];
        else if (hit1) active_block = data1[addr_index];
        else if (hit2) active_block = data2[addr_index];
        else if (hit3) active_block = data3[addr_index];
        else active_block = {BLOCK_SIZE{1'b0}};

        // Al doilea nivel de decizie: MUX 16:1 (Extragem cuvantul de 32 biti folosind Word Offset)
        read_data_word = active_block[(word_offset * 32) +: 32];
    end

    // 7. Logica Secventiala (Actualizare Memorie si Tranzitii)
    integer i;
    
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= IDLE;
            // Initializam toate liniile de cache ca fiind invalide la pornire
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid0[i] <= 0; valid1[i] <= 0; valid2[i] <= 0; valid3[i] <= 0;
                dirty0[i] <= 0; dirty1[i] <= 0; dirty2[i] <= 0; dirty3[i] <= 0;
                // Repartizam contoarele uniform pentru a preveni coliziunile de varsta initiale
                lru_cnt0[i] <= 2'b00; lru_cnt1[i] <= 2'b01; 
                lru_cnt2[i] <= 2'b10; lru_cnt3[i] <= 2'b11;
            end
        end else begin
            current_state <= next_state;

            // ACTUALIZARE LRU LA ACCESARE (Hit Cache)
            if (current_state == READ_HIT || current_state == WRITE_HIT) begin
                // Calea accesata primeste prioritatea maxima (3), iar celelalte scad doar daca sunt mai recente
                if (hit0 && lru_cnt0[addr_index] != 2'b11) begin
                    if (lru_cnt1[addr_index] > lru_cnt0[addr_index]) lru_cnt1[addr_index] <= lru_cnt1[addr_index] - 1;
                    if (lru_cnt2[addr_index] > lru_cnt0[addr_index]) lru_cnt2[addr_index] <= lru_cnt2[addr_index] - 1;
                    if (lru_cnt3[addr_index] > lru_cnt0[addr_index]) lru_cnt3[addr_index] <= lru_cnt3[addr_index] - 1;
                    lru_cnt0[addr_index] <= 2'b11;
                end else if (hit1 && lru_cnt1[addr_index] != 2'b11) begin
                    if (lru_cnt0[addr_index] > lru_cnt1[addr_index]) lru_cnt0[addr_index] <= lru_cnt0[addr_index] - 1;
                    if (lru_cnt2[addr_index] > lru_cnt1[addr_index]) lru_cnt2[addr_index] <= lru_cnt2[addr_index] - 1;
                    if (lru_cnt3[addr_index] > lru_cnt1[addr_index]) lru_cnt3[addr_index] <= lru_cnt3[addr_index] - 1;
                    lru_cnt1[addr_index] <= 2'b11;
                end else if (hit2 && lru_cnt2[addr_index] != 2'b11) begin
                    if (lru_cnt0[addr_index] > lru_cnt2[addr_index]) lru_cnt0[addr_index] <= lru_cnt0[addr_index] - 1;
                    if (lru_cnt1[addr_index] > lru_cnt2[addr_index]) lru_cnt1[addr_index] <= lru_cnt1[addr_index] - 1;
                    if (lru_cnt3[addr_index] > lru_cnt2[addr_index]) lru_cnt3[addr_index] <= lru_cnt3[addr_index] - 1;
                    lru_cnt2[addr_index] <= 2'b11;
                end else if (hit3 && lru_cnt3[addr_index] != 2'b11) begin
                    if (lru_cnt0[addr_index] > lru_cnt3[addr_index]) lru_cnt0[addr_index] <= lru_cnt0[addr_index] - 1;
                    if (lru_cnt1[addr_index] > lru_cnt3[addr_index]) lru_cnt1[addr_index] <= lru_cnt1[addr_index] - 1;
                    if (lru_cnt2[addr_index] > lru_cnt3[addr_index]) lru_cnt2[addr_index] <= lru_cnt2[addr_index] - 1;
                    lru_cnt3[addr_index] <= 2'b11;
                end
            end

            // OPERATIA DE SCRIERE IN CACHE DE LA PROCESOR (Write Hit)
            if (current_state == WRITE_HIT) begin
                if (hit0) begin data0[addr_index][(word_offset * 32) +: 32] <= write_data_word; dirty0[addr_index] <= 1; end
                if (hit1) begin data1[addr_index][(word_offset * 32) +: 32] <= write_data_word; dirty1[addr_index] <= 1; end
                if (hit2) begin data2[addr_index][(word_offset * 32) +: 32] <= write_data_word; dirty2[addr_index] <= 1; end
                if (hit3) begin data3[addr_index][(word_offset * 32) +: 32] <= write_data_word; dirty3[addr_index] <= 1; end
            end

            // ALOCAREA UNUI BLOC NOU ADUS DIN MEMORIA PRINCIPALA (Write Allocate / Fetch)
            if (current_state == ALLOCATE && mem_ready) begin
                // Calea selectata pentru evacuare (evict_way) devine acum MRU (Most Recently Used -> 3)
                lru_cnt0[addr_index] <= (evict_way == 2'b00) ? 2'b11 : lru_cnt0[addr_index] - 1;
                lru_cnt1[addr_index] <= (evict_way == 2'b01) ? 2'b11 : lru_cnt1[addr_index] - 1;
                lru_cnt2[addr_index] <= (evict_way == 2'b10) ? 2'b11 : lru_cnt2[addr_index] - 1;
                lru_cnt3[addr_index] <= (evict_way == 2'b11) ? 2'b11 : lru_cnt3[addr_index] - 1;

                // Suprascrierea blocului vechi cu noile date din RAM, validare si curatare bit dirty
                if (evict_way == 2'b00) begin valid0[addr_index] <= 1; dirty0[addr_index] <= 0; tag0[addr_index] <= addr_tag; data0[addr_index] <= mem_read_block; end
                else if (evict_way == 2'b01) begin valid1[addr_index] <= 1; dirty1[addr_index] <= 0; tag1[addr_index] <= addr_tag; data1[addr_index] <= mem_read_block; end
                else if (evict_way == 2'b10) begin valid2[addr_index] <= 1; dirty2[addr_index] <= 0; tag2[addr_index] <= addr_tag; data2[addr_index] <= mem_read_block; end
                else if (evict_way == 2'b11) begin valid3[addr_index] <= 1; dirty3[addr_index] <= 0; tag3[addr_index] <= addr_tag; data3[addr_index] <= mem_read_block; end
            end
        end
    end

    // 8. Logica Combinationala a FSM-ului (Next State Logic)
    always @(*) begin
        // Resetare semnale de control pentru prevenirea latch-urilor nedorite
        next_state = current_state;
        hit = 1'b0;
        miss = 1'b0;
        mem_read = 1'b0;
        mem_write = 1'b0;
        mem_address = 32'b0;
        mem_write_block = {BLOCK_SIZE{1'b0}};

        case (current_state)
            IDLE: begin
                if (read) begin
                    if (any_hit) next_state = READ_HIT;
                    else next_state = READ_MISS;
                end else if (write) begin
                    if (any_hit) next_state = WRITE_HIT;
                    else next_state = WRITE_MISS;
                end
            end

            READ_HIT: begin
                hit = 1'b1;
                next_state = IDLE;
            end

            WRITE_HIT: begin
                hit = 1'b1;
                next_state = IDLE;
            end

            READ_MISS, WRITE_MISS: begin
                miss = 1'b1;
                // Verificam starea blocului care urmeaza sa fie inlocuit (Write-Back Policy)
                if (evict_dirty) next_state = EVICT; // Necesita salvare in RAM
                else next_state = ALLOCATE;          // Bloc nemodificat, se poate suprascrie direct
            end

            EVICT: begin
                mem_write = 1'b1;
                // Reconstituim adresa completa a blocului vechi (Tag + Index + Offset zerorizat)
                mem_address = {evict_tag, addr_index, 6'b000000};
                mem_write_block = evict_data;

                if (mem_ready) next_state = ALLOCATE;
            end

            ALLOCATE: begin
                mem_read = 1'b1;
                // Semnalam memoriei principale adresa de unde trebuie citit blocul nou
                mem_address = {addr_tag, addr_index, 6'b000000};

                if (mem_ready) begin
                    // Dupa incarcarea cu succes, FSM-ul serveste comanda initiala a procesorului
                    if (read) next_state = READ_HIT;
                    else next_state = WRITE_HIT;
                end
            end

            default: next_state = IDLE;
        endcase
    end

endmodule