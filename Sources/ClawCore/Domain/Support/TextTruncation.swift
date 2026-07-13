/// The canonical marker appended where grapheme-budgeted text is cut short. One definition shared
/// by every truncation site (context fitting, tool-output capping) so a rendered cut always reads
/// the same to the model.
public enum TextTruncation {
  public static let marker = "…[truncated]"
}
