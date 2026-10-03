-- 16-bit hex counter on the 4-digit 7-segment display (multiplexed) and the low byte on the LEDs.
-- btn(0) clears, sw(0) = fast count.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
  port (
    clk : in  std_logic;
    btn : in  std_logic_vector(3 downto 0);
    sw  : in  std_logic_vector(7 downto 0);
    led : out std_logic_vector(7 downto 0);
    seg : out std_logic_vector(6 downto 0);  -- gfedcba, active-high
    dig : out std_logic_vector(3 downto 0)
  );
end entity;

architecture rtl of top is
  signal prescale : unsigned(23 downto 0) := (others => '0');
  signal count    : unsigned(15 downto 0) := (others => '0');
  signal sel      : unsigned(1 downto 0);
  signal nibble   : std_logic_vector(3 downto 0);
begin
  process (clk)
  begin
    if rising_edge(clk) then
      prescale <= prescale + 1;
      if btn(0) = '1' then
        count <= (others => '0');
      elsif (sw(0) = '0' and prescale = to_unsigned(2**24 - 1, 24)) or
            (sw(0) = '1' and prescale(19 downto 0) = to_unsigned(2**20 - 1, 20)) then
        count <= count + 1;
      end if;
    end if;
  end process;

  -- scan the four digits at clk / 2**16 (about 380 Hz per full scan)
  sel <= prescale(15 downto 14);
  dig <= "0001" when sel = "00" else
         "0010" when sel = "01" else
         "0100" when sel = "10" else
         "1000";
  nibble <= std_logic_vector(count(3 downto 0))   when sel = "00" else
            std_logic_vector(count(7 downto 4))   when sel = "01" else
            std_logic_vector(count(11 downto 8))  when sel = "10" else
            std_logic_vector(count(15 downto 12));

  with nibble select seg <=
    "0111111" when x"0", "0000110" when x"1", "1011011" when x"2", "1001111" when x"3",
    "1100110" when x"4", "1101101" when x"5", "1111101" when x"6", "0000111" when x"7",
    "1111111" when x"8", "1101111" when x"9", "1110111" when x"A", "1111100" when x"B",
    "0111001" when x"C", "1011110" when x"D", "1111001" when x"E", "1110001" when others;

  led <= std_logic_vector(count(7 downto 0));
end architecture;
