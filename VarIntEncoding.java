public class Main {
    
    public static void main(String[] args) {
        // varint(-1);
        // varint(-2147483648);
        varint(174);
    }
    
    private static final int SEGMENT_BITS = 0x7F;
    private static final int CONTINUE_BIT = 0x80;
    
    static void varint(int value) {
        System.out.printf("value %d: ", value);
        while (true) {
            if ((value & ~SEGMENT_BITS) == 0) {
                System.out.printf("0x%x\n", (byte)value);
                return;
            }
    
            System.out.printf("0x%x ", (byte) ((value &  SEGMENT_BITS) | CONTINUE_BIT));
            value >>>= 7;
        }
    }
}